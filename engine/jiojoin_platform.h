#ifndef JIOJOIN_PLATFORM_H
#define JIOJOIN_PLATFORM_H

#include <stdio.h>

#if defined(_WIN32)
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
static INIT_ONCE jiojoin_stdout_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION jiojoin_stdout_lock_value;
static BOOL CALLBACK jiojoin_initialize_stdout_lock(PINIT_ONCE once, PVOID parameter, PVOID *context)
{
    (void)once;
    (void)parameter;
    (void)context;
    InitializeCriticalSection(&jiojoin_stdout_lock_value);
    return TRUE;
}
static void jiojoin_stdout_lock(void)
{
    InitOnceExecuteOnce(&jiojoin_stdout_once, jiojoin_initialize_stdout_lock, NULL, NULL);
    EnterCriticalSection(&jiojoin_stdout_lock_value);
}
static void jiojoin_stdout_unlock(void)
{
    LeaveCriticalSection(&jiojoin_stdout_lock_value);
}
#define jiojoin_strtok_r strtok_s
#else
static void jiojoin_stdout_lock(void) { flockfile(stdout); }
static void jiojoin_stdout_unlock(void) { funlockfile(stdout); }
#define jiojoin_strtok_r strtok_r
#endif

static const char *jiojoin_platform_name(void)
{
#if defined(_WIN32)
    return "windows";
#elif defined(__APPLE__)
    return "macos";
#elif defined(__linux__)
    return "linux";
#else
    return "unknown";
#endif
}

static const char *jiojoin_architecture_name(void)
{
#if defined(__aarch64__) || defined(_M_ARM64)
    return "arm64";
#elif defined(__x86_64__) || defined(_M_X64)
    return "x86_64";
#elif defined(__i386__) || defined(_M_IX86)
    return "x86";
#else
    return "unknown";
#endif
}

static const char *jiojoin_audio_backend_name(void)
{
#if defined(_WIN32)
    return "WASAPI";
#elif defined(__APPLE__)
    return "CoreAudio";
#elif defined(__linux__)
    return "ALSA/PipeWire";
#else
    return "system audio";
#endif
}

#endif
