// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { BO2_STEAM_PROVIDER_VERSION = 1 };
enum { BO2_STEAM_PENDING = 0, BO2_STEAM_READY = 1,
       BO2_STEAM_FAILED = -1, BO2_STEAM_BUFFER_TOO_SMALL = -2 };

// Callbacks run on game threads. They must copy inputs before returning and
// read synchronized snapshots; they must never wait for MainActor/network work.
// The owner retains context through game exit and all in-flight callbacks.
typedef struct BO2SteamProviderV1 {
    uint32_t version;
    uint32_t structSize;
    void *context;
    uint64_t (*steamID)(void *context);
    bool (*isLoggedOn)(void *context);
    bool (*ownsApp)(void *context, uint32_t appID);
    bool (*dlcInstalled)(void *context, uint32_t appID);
    uint64_t (*requestEncryptedTicket)(void *context, const void *userData, uint32_t size);
    int32_t (*pollEncryptedTicket)(void *context, uint64_t handle, void *destination,
                                  uint32_t capacity, uint32_t *requiredSize, uint32_t *steamResult);
    void (*releaseTicket)(void *context, uint64_t handle);
} BO2SteamProviderV1;

bool bo2_ios_set_steam_provider(const BO2SteamProviderV1 *provider);
BO2SteamProviderV1 bo2_ios_steam_provider_snapshot(void);
// Copies only a complete, stable successful ticket. Failure/short-buffer paths
// leave destination untouched. A null destination with capacity 0 probes size.
int32_t bo2_steam_copy_encrypted_ticket(uint64_t handle, void *destination, uint32_t capacity,
                                      uint32_t *requiredSize, uint32_t *steamResult);

#ifdef __cplusplus
}
#endif
