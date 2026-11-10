// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
#include "SteamRuntimeProvider.h"
#include "SteamRuntimeCalls.h"
#include <atomic>
#include <cstring>
#include <memory>
#include <map>
#include <mutex>
#include <vector>

namespace {
std::shared_ptr<const BO2SteamProviderV1> active;
constexpr uint32_t maxTicketBytes = 64 * 1024;
}

extern "C" bool bo2_ios_set_steam_provider(const BO2SteamProviderV1 *provider) {
    if (!provider || provider->version != BO2_STEAM_PROVIDER_VERSION ||
        provider->structSize < sizeof(BO2SteamProviderV1) || !provider->context ||
        !provider->steamID || !provider->isLoggedOn || !provider->ownsApp ||
        !provider->dlcInstalled || !provider->requestEncryptedTicket ||
        !provider->pollEncryptedTicket || !provider->releaseTicket) return false;
    auto copy = std::make_shared<const BO2SteamProviderV1>(*provider);
    std::atomic_store_explicit(&active, std::move(copy), std::memory_order_release);
    return true;
}

extern "C" BO2SteamProviderV1 bo2_ios_steam_provider_snapshot(void) {
    auto provider = std::atomic_load_explicit(&active, std::memory_order_acquire);
    return provider ? *provider : BO2SteamProviderV1{};
}

static int32_t copyTicket(const BO2SteamProviderV1 *provider, uint64_t handle, void *destination,
        uint32_t capacity, uint32_t *requiredSize, uint32_t *steamResult) {
    if (requiredSize) *requiredSize = 0;
    if (steamResult) *steamResult = 8; // InvalidParam
    if (!requiredSize || !steamResult || !handle || (!destination && capacity)) return BO2_STEAM_FAILED;
    if (!provider) { *steamResult = 3; return BO2_STEAM_FAILED; }
    int32_t state = provider->pollEncryptedTicket(provider->context, handle, nullptr, 0,
                                                 requiredSize, steamResult);
    if (state == BO2_STEAM_PENDING) { *requiredSize = 0; *steamResult = 0; return state; }
    if (state == BO2_STEAM_FAILED) {
        if (*steamResult == 0 || *steamResult == 1) *steamResult = 2;
        *requiredSize = 0;
        return state;
    }
    if ((state != BO2_STEAM_READY && state != BO2_STEAM_BUFFER_TOO_SMALL) ||
        *steamResult != 1 || !*requiredSize || *requiredSize > maxTicketBytes) {
        *steamResult = 2; return BO2_STEAM_FAILED;
    }
    if (capacity < *requiredSize || !destination) return BO2_STEAM_BUFFER_TOO_SMALL;
    const uint32_t size = *requiredSize;
    std::vector<uint8_t> bytes(size);
    uint32_t actual = 0, result = 0;
    state = provider->pollEncryptedTicket(provider->context, handle, bytes.data(), size, &actual, &result);
    if (state != BO2_STEAM_READY || actual != size || result != 1) {
        *requiredSize = actual;
        *steamResult = result == 1 ? 2 : result;
        return BO2_STEAM_FAILED;
    }
    std::memcpy(destination, bytes.data(), size);
    *steamResult = result;
    return BO2_STEAM_READY;
}

extern "C" int32_t bo2_steam_copy_encrypted_ticket(uint64_t handle, void *destination,
        uint32_t capacity, uint32_t *requiredSize, uint32_t *steamResult) {
    auto provider = std::atomic_load_explicit(&active, std::memory_order_acquire);
    return copyTicket(provider.get(), handle, destination, capacity, requiredSize, steamResult);
}

struct BO2SteamRuntimeCalls::Impl {
    struct Call { BO2SteamProviderV1 provider; uint64_t ticket; uint32_t callback = 0; };
    std::mutex mutex;
    uint64_t next = 0;
    std::map<uint64_t, Call> calls;
    Call current{};
    static void release(const Call &call) {
        if (call.ticket) call.provider.releaseTicket(call.provider.context,call.ticket);
    }
    ~Impl() {
        for (const auto &entry : calls) release(entry.second);
        release(current);
    }
};

BO2SteamRuntimeCalls::BO2SteamRuntimeCalls() : impl(new Impl) {}
BO2SteamRuntimeCalls::~BO2SteamRuntimeCalls() = default;

uint64_t BO2SteamRuntimeCalls::request(const void *data, uint32_t size) {
    if (size > maxTicketBytes || (size && !data)) return 0;
    auto provider = bo2_ios_steam_provider_snapshot();
    if (!provider.context) return 0;
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (impl->calls.size() >= 128) return 0;
    const uint64_t ticket = provider.requestEncryptedTicket(provider.context,data,size);
    if (!ticket) return 0;
    const uint64_t call = ++impl->next;
    impl->calls.emplace(call,Impl::Call{provider,ticket,0});
    return call;
}

void BO2SteamRuntimeCalls::registerCallback(uint64_t call, uint32_t callback) {
    std::lock_guard<std::mutex> lock(impl->mutex);
    auto it = impl->calls.find(call);
    if (it != impl->calls.end()) it->second.callback = callback;
}
void BO2SteamRuntimeCalls::unregisterCallback(uint64_t call) { registerCallback(call,0); }

std::vector<BO2SteamRuntimeCalls::Completion> BO2SteamRuntimeCalls::drain() {
    std::vector<Completion> done;
    std::lock_guard<std::mutex> lock(impl->mutex);
    for (auto it=impl->calls.begin(); it!=impl->calls.end();) {
        auto &call=it->second;
        if (!call.callback) { ++it; continue; }
        uint32_t size=0,result=0;
        const int32_t state=::copyTicket(&call.provider,call.ticket,nullptr,0,&size,&result);
        if (state==BO2_STEAM_PENDING) { ++it; continue; }
        done.push_back({it->first,call.callback,result});
        if (state==BO2_STEAM_BUFFER_TOO_SMALL && result==1) {
            Impl::release(impl->current);
            impl->current=call;
        } else { Impl::release(call); }
        it=impl->calls.erase(it);
    }
    return done;
}

int32_t BO2SteamRuntimeCalls::copyTicket(void *destination,uint32_t capacity,
        uint32_t *requiredSize,uint32_t *steamResult) {
    std::lock_guard<std::mutex> lock(impl->mutex);
    const auto &call=impl->current;
    return ::copyTicket(call.ticket ? &call.provider : nullptr,call.ticket,
                        destination,capacity,requiredSize,steamResult);
}
