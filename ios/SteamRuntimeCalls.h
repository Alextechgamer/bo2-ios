// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
#pragma once
#include "SteamRuntimeProvider.h"
#include <memory>
#include <vector>

// Framework-owned, thread-safe call/result adapter. Guest addresses remain
// opaque here; the runtime invokes completed callbacks outside this adapter.
class BO2SteamRuntimeCalls {
public:
    struct Completion { uint64_t call; uint32_t callback; uint32_t result; };
    BO2SteamRuntimeCalls();
    ~BO2SteamRuntimeCalls();
    BO2SteamRuntimeCalls(const BO2SteamRuntimeCalls&) = delete;
    BO2SteamRuntimeCalls& operator=(const BO2SteamRuntimeCalls&) = delete;
    uint64_t request(const void *data, uint32_t size);
    void registerCallback(uint64_t call, uint32_t callback);
    void unregisterCallback(uint64_t call);
    std::vector<Completion> drain();
    int32_t copyTicket(void *destination, uint32_t capacity,
                       uint32_t *requiredSize, uint32_t *steamResult);
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
