/*
 * JioJoin desktop engine — a small headless softphone built on upstream PJSIP.
 *
 * It accepts tab-separated commands on stdin. String fields are base64 encoded,
 * so credentials never appear in argv or process listings. It emits JSON lines
 * on stdout; PJSIP diagnostics are written to stderr.
 *
 * SPDX-License-Identifier: GPL-2.0-only
 */

#include <pjsua-lib/pjsua.h>
#include <pjmedia-audiodev/audiodev.h>
#include <pjmedia/port.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jiojoin_platform.h"
#include "jiojoin_protocol.h"

#define MAX_LINE 16384
#define MAX_FIELD 4096

static pjsua_acc_id g_account = PJSUA_INVALID_ID;
static pjsua_call_id g_call = PJSUA_INVALID_ID;
static char g_realm[256];
static char g_pani[512];
static int g_started;
static pj_status_t configure_audio_devices_from_environment(pj_bool_t immediate_open);
static void emit_event(const char *type, const char *message, int code);
static void emit_error(const char *operation, pj_status_t status);
static void emit_status(void);
static void emit_hello(void);
static void apply_call_media_routing(pjsua_call_id call_id);

static pj_status_t add_jio_headers(pjsip_tx_data *data)
{
    pj_str_t name = pj_str("P-Access-Network-Info");
    pj_str_t value = pj_str(g_pani);
    pjsip_generic_string_hdr *header;
    if (!g_pani[0] || pjsip_msg_find_hdr_by_name(data->msg, &name, NULL)) return PJ_SUCCESS;
    header = pjsip_generic_string_hdr_create(data->pool, &name, &value);
    pjsip_msg_add_hdr(data->msg, (pjsip_hdr *)header);
    return PJ_SUCCESS;
}

static pjsip_module g_jio_header_module = {
    .name = {"mod-jio-headers", 15},
    .id = -1,
    .priority = PJSIP_MOD_PRIORITY_APPLICATION,
    .on_tx_request = &add_jio_headers
};

static void emit_escaped(const char *value)
{
    const unsigned char *p = (const unsigned char *)(value ? value : "");
    for (; *p; ++p) {
        switch (*p) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*p < 0x20) fprintf(stdout, "\\u%04x", *p);
            else fputc(*p, stdout);
        }
    }
}

static void emit_event(const char *type, const char *message, int code)
{
    jiojoin_stdout_lock();
    fputs("{\"event\":\"", stdout); emit_escaped(type);
    fputs("\",\"message\":\"", stdout); emit_escaped(message);
    fprintf(stdout, "\",\"code\":%d}\n", code);
    fflush(stdout);
    jiojoin_stdout_unlock();
}

static void emit_error(const char *operation, pj_status_t status)
{
    char error[PJ_ERR_MSG_SIZE];
    pj_strerror(status, error, sizeof(error));
    jiojoin_stdout_lock();
    fputs("{\"event\":\"error\",\"operation\":\"", stdout);
    emit_escaped(operation);
    fputs("\",\"message\":\"", stdout); emit_escaped(error);
    fprintf(stdout, "\",\"code\":%d}\n", status);
    fflush(stdout);
    jiojoin_stdout_unlock();
}

static void emit_hello(void)
{
    jiojoin_stdout_lock();
    fprintf(stdout,
            "{\"event\":\"hello\",\"message\":\"JioJoin headless engine\","
            "\"code\":0,\"protocol\":%d,\"engine_version\":\"%s\","
            "\"platform\":\"%s\",\"architecture\":\"%s\","
            "\"audio_backend\":\"%s\",\"commands\":\"%s\"}\n",
            JIOJOIN_PROTOCOL_VERSION, JIOJOIN_ENGINE_VERSION,
            jiojoin_platform_name(), jiojoin_architecture_name(),
            jiojoin_audio_backend_name(), JIOJOIN_PROTOCOL_COMMANDS);
    fflush(stdout);
    jiojoin_stdout_unlock();
}

static void emit_status(void)
{
    pjsua_acc_info account_info;
    pj_bool_t is_registered = PJ_FALSE;
    pj_bool_t has_active_call = PJ_FALSE;
    int registration_code = 0;

    if (g_started && g_account != PJSUA_INVALID_ID &&
        pjsua_acc_get_info(g_account, &account_info) == PJ_SUCCESS) {
        registration_code = account_info.status;
        is_registered = account_info.status == 200;
    }
    if (g_started && g_call != PJSUA_INVALID_ID)
        has_active_call = pjsua_call_is_active(g_call);

    jiojoin_stdout_lock();
    fprintf(stdout,
            "{\"event\":\"status\",\"message\":\"engine status\",\"code\":%d,"
            "\"registered\":%s,\"active_call\":%s}\n",
            registration_code,
            is_registered ? "true" : "false",
            has_active_call ? "true" : "false");
    fflush(stdout);
    jiojoin_stdout_unlock();
}

static int b64_value(unsigned char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static int decode_field(const char *input, char *output, size_t capacity)
{
    unsigned accumulator = 0;
    int bits = 0;
    size_t used = 0;
    const unsigned char *p = (const unsigned char *)input;
    for (; *p && *p != '\n' && *p != '\r'; ++p) {
        int value;
        if (*p == '=') break;
        value = b64_value(*p);
        if (value < 0) return -1;
        accumulator = (accumulator << 6) | (unsigned)value;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (used + 1 >= capacity) return -1;
            output[used++] = (char)((accumulator >> bits) & 0xff);
        }
    }
    output[used] = '\0';
    return (int)used;
}

static void pjsip_log_writer(int level, const char *data, int len)
{
    PJ_UNUSED_ARG(level);
    fwrite(data, 1, (size_t)len, stderr);
    fflush(stderr);
}

static void on_reg_state(pjsua_acc_id account, pjsua_reg_info *info)
{
    pjsua_acc_info account_info;
    PJ_UNUSED_ARG(info);
    if (pjsua_acc_get_info(account, &account_info) == PJ_SUCCESS) {
        char message[512];
        int n = pj_ansi_snprintf(message, sizeof(message), "%.*s",
                                (int)account_info.status_text.slen,
                                account_info.status_text.ptr);
        if (n < 0) message[0] = '\0';
        emit_event(account_info.status == 200 ? "registered" : "registration",
                   message, account_info.status);
    }
}

static void on_incoming_call(pjsua_acc_id account, pjsua_call_id call_id,
                             pjsip_rx_data *data)
{
    pjsua_call_info info;
    char remote[512] = "Incoming call";
    PJ_UNUSED_ARG(account);
    PJ_UNUSED_ARG(data);
    g_call = call_id;
    if (pjsua_call_get_info(call_id, &info) == PJ_SUCCESS) {
        pj_ansi_snprintf(remote, sizeof(remote), "%.*s",
                        (int)info.remote_info.slen, info.remote_info.ptr);
    }
    pjsua_call_answer(call_id, 180, NULL, NULL);
    emit_event("incoming", remote, call_id);
}

static void on_call_state(pjsua_call_id call_id, pjsip_event *event)
{
    pjsua_call_info info;
    char state[128] = "unknown";
    PJ_UNUSED_ARG(event);
    if (pjsua_call_get_info(call_id, &info) == PJ_SUCCESS) {
        pj_ansi_snprintf(state, sizeof(state), "%.*s",
                        (int)info.state_text.slen, info.state_text.ptr);
        emit_event("call-state", state, info.last_status);
        if (info.state == PJSIP_INV_STATE_DISCONNECTED) g_call = PJSUA_INVALID_ID;
    }
}

static void on_call_media_state(pjsua_call_id call_id)
{
    pjsua_call_info info;
    if (pjsua_call_get_info(call_id, &info) != PJ_SUCCESS) return;
    if (info.media_status == PJSUA_CALL_MEDIA_LOCAL_HOLD) {
        emit_event("held", "Call on hold", call_id);
    } else if (info.media_status == PJSUA_CALL_MEDIA_REMOTE_HOLD) {
        emit_event("remote-held", "The other party placed the call on hold", call_id);
    } else if (info.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
        apply_call_media_routing(call_id);
    }
}

static void apply_call_media_routing(pjsua_call_id call_id)
{
    pjsua_call_info info;
    pj_status_t status;
    int capture_id = -1, playback_id = -1;
    char message[128];
    if (pjsua_call_get_info(call_id, &info) != PJ_SUCCESS ||
        info.conf_slot == PJSUA_INVALID_ID)
        return;

    status = configure_audio_devices_from_environment(PJ_TRUE);
    if (status != PJ_SUCCESS) {
        emit_error("call-media-audio-device", status);
        return;
    }
    if (pjsua_get_snd_dev(&capture_id, &playback_id) == PJ_SUCCESS) {
        pj_ansi_snprintf(message, sizeof(message),
                         "active capture=%d playback=%d",
                         capture_id, playback_id);
        emit_event("audio-device", message, call_id);
    }
    pjsua_conf_connect(info.conf_slot, 0);
    pjsua_conf_connect(0, info.conf_slot);
    emit_event("media", "System audio connected", call_id);
}

static void set_jio_codecs(void)
{
    pjsua_codec_info codecs[64];
    unsigned count = PJ_ARRAY_SIZE(codecs);
    unsigned i;
    const pj_str_t amrwb = pj_str("AMR-WB/16000/1");
    const pj_str_t amr = pj_str("AMR/8000/1");
    const pj_str_t pcmu = pj_str("PCMU/8000/1");
    if (pjsua_enum_codecs(codecs, &count) != PJ_SUCCESS) return;
    for (i = 0; i < count; ++i) {
        pj_uint8_t priority = 0;
        if (!pj_stricmp(&codecs[i].codec_id, &amrwb)) priority = 255;
        else if (!pj_stricmp(&codecs[i].codec_id, &amr)) priority = 254;
        else if (!pj_stricmp(&codecs[i].codec_id, &pcmu)) priority = 128;
        pjsua_codec_set_priority(&codecs[i].codec_id, priority);
    }
}

static pj_status_t configure_audio_devices_from_environment(pj_bool_t immediate_open)
{
    const char *capture_name = getenv("JIOJOIN_CAPTURE_DEVICE");
    const char *playback_name = getenv("JIOJOIN_PLAYBACK_DEVICE");
    pjmedia_aud_dev_info devices[64];
    pjsua_snd_dev_param parameters;
    unsigned count = PJ_ARRAY_SIZE(devices);
    unsigned i;
    int capture_id = -1, playback_id = -1;
    pj_status_t status;
    char message[512];

    if ((!capture_name || !*capture_name) && (!playback_name || !*playback_name))
        return PJ_SUCCESS;
    if (!capture_name || !*capture_name || !playback_name || !*playback_name) {
        emit_event("error", "Both explicit audio device names are required", 400);
        return PJ_EINVAL;
    }

    status = pjsua_enum_aud_devs(devices, &count);
    if (status != PJ_SUCCESS) {
        emit_error("audio-device-enumeration", status);
        return status;
    }
    for (i = 0; i < count; ++i) {
        if (capture_id < 0 && devices[i].input_count > 0 &&
            !strcmp(devices[i].name, capture_name))
            capture_id = devices[i].id;
        if (playback_id < 0 && devices[i].output_count > 0 &&
            !strcmp(devices[i].name, playback_name))
            playback_id = devices[i].id;
    }
    if (capture_id < 0 || playback_id < 0) {
        pj_ansi_snprintf(message, sizeof(message),
                         "Audio device unavailable: capture=%s playback=%s",
                         capture_name, playback_name);
        emit_event("error", message, 404);
        return PJ_ENOTFOUND;
    }

    pjsua_snd_dev_param_default(&parameters);
    parameters.capture_dev = capture_id;
    parameters.playback_dev = playback_id;
    parameters.use_default_settings = PJ_TRUE;
    if (!immediate_open) parameters.mode |= PJSUA_SND_DEV_NO_IMMEDIATE_OPEN;
    status = pjsua_set_snd_dev2(&parameters);
    if (status != PJ_SUCCESS) {
        emit_error("audio-device-selection", status);
        return status;
    }

    pj_ansi_snprintf(message, sizeof(message),
                     "capture=%s playback=%s", capture_name, playback_name);
    emit_event("audio-device", message, 0);
    return PJ_SUCCESS;
}

static pj_status_t initialize_stack(int self_test)
{
    pjsua_config config;
    pjsua_logging_config logging;
    pjsua_media_config media;
    pj_status_t status;

    status = pjsua_create();
    if (status != PJ_SUCCESS) return status;
    pjsua_config_default(&config);
    pjsua_logging_config_default(&logging);
    pjsua_media_config_default(&media);
    config.user_agent = pj_str("JioJoinDesktop/0.8 JUICEJSE/1.4.3");
    config.cb.on_reg_state2 = &on_reg_state;
    config.cb.on_incoming_call = &on_incoming_call;
    config.cb.on_call_state = &on_call_state;
    config.cb.on_call_media_state = &on_call_media_state;
    config.thread_cnt = 2;
    logging.level = 4;
    logging.console_level = 4;
    logging.cb = &pjsip_log_writer;
    media.clock_rate = 16000;
    media.snd_clock_rate = 48000;
    media.audio_frame_ptime = 20;
    media.ec_tail_len = 200;
    if (self_test) media.no_vad = PJ_TRUE;
    status = pjsua_init(&config, &logging, &media);
    if (status == PJ_SUCCESS)
        status = pjsip_endpt_register_module(pjsua_get_pjsip_endpt(), &g_jio_header_module);
    return status;
}

static int run_self_test(void)
{
    pj_status_t status = initialize_stack(1);
    pjsua_transport_config transport;
    pjsua_transport_id transport_id;
    pjsua_codec_info codecs[64];
    pjmedia_aud_dev_info devices[32];
    unsigned codec_count = PJ_ARRAY_SIZE(codecs);
    unsigned device_count = PJ_ARRAY_SIZE(devices);
    unsigned i;
    int has_amr = 0, has_amrwb = 0;
    if (status != PJ_SUCCESS) { emit_error("initialize", status); return 1; }
    pjsua_transport_config_default(&transport);
    transport.port = 0;
    transport.tls_setting.verify_server = PJ_FALSE;
    transport.tls_setting.verify_client = PJ_FALSE;
    status = pjsua_transport_create(PJSIP_TRANSPORT_TLS, &transport, &transport_id);
    if (status != PJ_SUCCESS) { emit_error("tls-transport", status); pjsua_destroy(); return 1; }
    status = pjsua_start();
    if (status != PJ_SUCCESS) { emit_error("start", status); pjsua_destroy(); return 1; }
    pjsua_set_null_snd_dev();
    if (pjsua_enum_codecs(codecs, &codec_count) == PJ_SUCCESS) {
        for (i = 0; i < codec_count; ++i) {
            if (pj_strnicmp2(&codecs[i].codec_id, "AMR-WB/", 7) == 0) has_amrwb = 1;
            if (pj_strnicmp2(&codecs[i].codec_id, "AMR/", 4) == 0) has_amr = 1;
        }
    }
    if (pjsua_enum_aud_devs(devices, &device_count) != PJ_SUCCESS) device_count = 0;
    jiojoin_stdout_lock();
    fprintf(stdout, "{\"event\":\"self-test\",\"tls\":true,\"amr\":%s,\"amr_wb\":%s,\"audio_devices\":%u,\"platform\":\"%s\",\"architecture\":\"%s\",\"audio_backend\":\"%s\"}\n",
            has_amr ? "true" : "false", has_amrwb ? "true" : "false", device_count,
            jiojoin_platform_name(), jiojoin_architecture_name(), jiojoin_audio_backend_name());
    fflush(stdout);
    jiojoin_stdout_unlock();
    pjsua_destroy();
    return has_amr && has_amrwb ? 0 : 2;
}

static int run_audio_device_test(void)
{
    pj_status_t status = initialize_stack(1);
    if (status != PJ_SUCCESS) {
        emit_error("initialize", status);
        return 1;
    }
    status = pjsua_start();
    if (status == PJ_SUCCESS)
        status = configure_audio_devices_from_environment(PJ_TRUE);
    if (status == PJ_SUCCESS)
        emit_event("self-test", "Explicit system audio devices opened", 0);
    pjsua_destroy();
    return status == PJ_SUCCESS ? 0 : 1;
}

static pj_status_t start_account(char **fields, int count)
{
    char public_id[MAX_FIELD], auth_user[MAX_FIELD], password[MAX_FIELD];
    char realm[MAX_FIELD], registrar[MAX_FIELD], instance[MAX_FIELD];
    char local_ip[MAX_FIELD], pani[MAX_FIELD];
    pjsua_transport_config transport;
    pjsua_transport_id transport_id;
    pjsua_acc_config account;
    pj_status_t status;

    if (count != 9 || decode_field(fields[1], public_id, sizeof(public_id)) < 0 ||
        decode_field(fields[2], auth_user, sizeof(auth_user)) < 0 ||
        decode_field(fields[3], password, sizeof(password)) < 0 ||
        decode_field(fields[4], realm, sizeof(realm)) < 0 ||
        decode_field(fields[5], registrar, sizeof(registrar)) < 0 ||
        decode_field(fields[6], instance, sizeof(instance)) < 0 ||
        decode_field(fields[7], local_ip, sizeof(local_ip)) < 0 ||
        decode_field(fields[8], pani, sizeof(pani)) < 0) {
        emit_event("error", "Invalid START command", 400);
        return PJ_EINVAL;
    }
    if (g_started) {
        if (g_call != PJSUA_INVALID_ID && pjsua_call_is_active(g_call)) {
            emit_event("error", "Registration cannot restart during an active call", 409);
            return PJ_EBUSY;
        }
        emit_event("engine", "Restarting registration with refreshed configuration", 0);
        pjsua_destroy();
        g_started = 0;
        g_account = PJSUA_INVALID_ID;
        g_call = PJSUA_INVALID_ID;
    }
    strncpy(g_pani, pani, sizeof(g_pani) - 1);
    g_pani[sizeof(g_pani) - 1] = '\0';
    status = initialize_stack(0);
    if (status != PJ_SUCCESS) { emit_error("initialize", status); return status; }

    pjsua_transport_config_default(&transport);
    transport.port = 5062;
    if (*local_ip) transport.bound_addr = pj_str(local_ip);
    transport.tls_setting.verify_server = PJ_FALSE;
    transport.tls_setting.verify_client = PJ_FALSE;
    transport.tls_setting.method = PJSIP_SSL_UNSPECIFIED_METHOD;
    status = pjsua_transport_create(PJSIP_TRANSPORT_TLS, &transport, &transport_id);
    if (status != PJ_SUCCESS) { emit_error("tls-transport", status); pjsua_destroy(); return status; }
    status = pjsua_start();
    if (status != PJ_SUCCESS) { emit_error("start", status); pjsua_destroy(); return status; }
    status = configure_audio_devices_from_environment(PJ_TRUE);
    if (status != PJ_SUCCESS) { pjsua_destroy(); return status; }
    set_jio_codecs();

    pjsua_acc_config_default(&account);
    account.id = pj_str(public_id);
    account.reg_uri = pj_str(registrar);
    account.proxy_cnt = 1;
    account.proxy[0] = pj_str(registrar);
    account.transport_id = transport_id;
    account.cred_count = 1;
    account.cred_info[0].realm = pj_str(realm);
    account.cred_info[0].scheme = pj_str("digest");
    account.cred_info[0].username = pj_str(auth_user);
    account.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    account.cred_info[0].data = pj_str(password);
    account.use_rfc5626 = PJ_TRUE;
    account.rfc5626_instance_id = pj_str(instance);
    account.reg_timeout = 86400;
    account.require_100rel = PJSUA_100REL_OPTIONAL;
    account.reg_contact_params = pj_str(
        ";+g.3gpp.icsi-ref=\"urn%3Aurn-7%3A3gpp-service.ims.icsi.mmtel\""
        ";video"
        ";+g.3gpp.iari-ref=\"urn%3Aurn-7%3A3gpp-application.ims.iari.rcs.jio.eucr\""
        ";+g.gsma.rcs.telephony=\"none\";q=0.5");
    pjsua_transport_config_default(&account.rtp_cfg);
    account.rtp_cfg.port = 52000;
    if (*local_ip) {
        account.rtp_cfg.bound_addr = pj_str(local_ip);
        account.rtp_cfg.public_addr = pj_str(local_ip);
    }
    strncpy(g_realm, realm, sizeof(g_realm) - 1);
    status = pjsua_acc_add(&account, PJ_TRUE, &g_account);
    memset(password, 0, sizeof(password));
    if (status != PJ_SUCCESS) { emit_error("account", status); pjsua_destroy(); return status; }
    g_started = 1;
    emit_event("engine", "Registration started", 0);
    return PJ_SUCCESS;
}

static void dial_number(const char *encoded)
{
    char number[128], uri[512];
    pj_str_t destination;
    pj_status_t status;
    if (!g_started || decode_field(encoded, number, sizeof(number)) < 0) {
        emit_event("error", "Engine is not registered or number is invalid", 400); return;
    }
    if (g_call != PJSUA_INVALID_ID && pjsua_call_is_active(g_call)) {
        emit_event("error", "A call is already active", 409); return;
    }
    pj_ansi_snprintf(uri, sizeof(uri), "sip:%s@%s?phone-context=%s&user=phone",
                    number, g_realm, g_realm);
    destination = pj_str(uri);
    status = pjsua_call_make_call(g_account, &destination, NULL, NULL, NULL, &g_call);
    if (status != PJ_SUCCESS) emit_error("dial", status);
    else emit_event("dialing", number, g_call);
}

static void set_call_hold(pj_bool_t hold)
{
    pj_status_t status;
    if (g_call == PJSUA_INVALID_ID || !pjsua_call_is_active(g_call)) {
        emit_event("error", "There is no active call to hold", 409);
        return;
    }
    if (hold)
        status = pjsua_call_set_hold(g_call, NULL);
    else
        status = pjsua_call_reinvite(g_call, PJSUA_CALL_UNHOLD, NULL);
    if (status != PJ_SUCCESS)
        emit_error(hold ? "hold" : "resume", status);
    else
        emit_event(hold ? "held" : "resumed",
                   hold ? "Call on hold" : "Call resumed", g_call);
}

static void handle_line(char *line)
{
    char *fields[12];
    char *save = NULL;
    int count = 0;
    char *token = jiojoin_strtok_r(line, "\t\r\n", &save);
    while (token && count < (int)PJ_ARRAY_SIZE(fields)) {
        fields[count++] = token;
        token = jiojoin_strtok_r(NULL, "\t\r\n", &save);
    }
    if (!count) return;
    if (!strcmp(fields[0], "HELLO")) emit_hello();
    else if (!strcmp(fields[0], "PING")) emit_event("pong", "ok", 0);
    else if (!strcmp(fields[0], "STATUS")) emit_status();
    else if (!strcmp(fields[0], "START")) start_account(fields, count);
    else if (!strcmp(fields[0], "DIAL") && count == 2) dial_number(fields[1]);
    else if (!strcmp(fields[0], "ANSWER") && g_call != PJSUA_INVALID_ID)
        pjsua_call_answer(g_call, 200, NULL, NULL);
    else if (!strcmp(fields[0], "REJECT") && g_call != PJSUA_INVALID_ID)
        pjsua_call_answer(g_call, 603, NULL, NULL);
    else if (!strcmp(fields[0], "HANGUP") && g_call != PJSUA_INVALID_ID)
        pjsua_call_hangup(g_call, 0, NULL, NULL);
    else if (!strcmp(fields[0], "HOLD")) set_call_hold(PJ_TRUE);
    else if (!strcmp(fields[0], "RESUME")) set_call_hold(PJ_FALSE);
    else if (!strcmp(fields[0], "QUIT")) {
        if (g_started) pjsua_destroy();
        exit(0);
    } else emit_event("error", "Unknown or unavailable command", 400);
}

int main(int argc, char **argv)
{
    char line[MAX_LINE];
    if (argc == 2 && !strcmp(argv[1], "--version")) { emit_hello(); return 0; }
    if (argc == 2 && !strcmp(argv[1], "--self-test")) return run_self_test();
    if (argc == 2 && !strcmp(argv[1], "--audio-device-test")) return run_audio_device_test();
    if (argc != 1 && !(argc == 2 && !strcmp(argv[1], "--stdio"))) {
        fputs("Usage: jiojoin-engine [--stdio|--version|--self-test|--audio-device-test]\n", stderr);
        return 64;
    }
    emit_hello();
    emit_event("engine", "Ready; no network registration has started", 0);
    while (fgets(line, sizeof(line), stdin)) handle_line(line);
    if (g_started) pjsua_destroy();
    return 0;
}
