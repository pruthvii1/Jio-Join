#ifndef JIOJOIN_PROTOCOL_H
#define JIOJOIN_PROTOCOL_H

#define JIOJOIN_ENGINE_VERSION "0.8.0"
#define JIOJOIN_PROTOCOL_VERSION 1

/*
 * The stdio protocol is deliberately small and line-oriented. Commands never
 * carry credentials in argv; START and DIAL fields are base64-encoded and are
 * accepted only over stdin. Responses are one JSON object per stdout line.
 */
#define JIOJOIN_PROTOCOL_COMMANDS \
    "HELLO,START,PING,STATUS,DIAL,ANSWER,REJECT,HANGUP,HOLD,RESUME,QUIT"

#endif
