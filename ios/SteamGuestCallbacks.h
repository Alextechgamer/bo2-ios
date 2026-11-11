// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 BO2 iOS contributors
#pragma once
#include "SteamRuntimeProvider.h"

namespace bo2SteamGuest {
struct RestoreStack {
    uint32_t &stack;
    const uint32_t saved;
    ~RestoreStack() { stack = saved; }
};
// A response occupies sixteen bytes so adding it preserves the original x86
// call alignment. It lives until the synchronous guest callback returns.
constexpr uint32_t responseReservation = 16;
}

template<class Write32, class Read32, class Invoke>
bool bo2SteamDeliverCallResult(uint32_t &stack, uint32_t &thisArgument,
        uint32_t object, uint64_t call, uint32_t result, Write32 write,
        Read32 read, Invoke invoke) {
    const bo2SteamGuest::RestoreStack restore{stack,stack};
    const uint32_t response=stack-bo2SteamGuest::responseReservation;
    write(response,result); write(response+4,0);
    const uint32_t frame=response-20;
    write(frame,0xDEAD0000u);
    write(frame+4,response);
    write(frame+8,0); // The completed request carries its own EResult.
    write(frame+12,(uint32_t)call);
    write(frame+16,(uint32_t)(call>>32));
    // Memory helpers may inspect the active guest state. Publish ESP only
    // once the complete frame is ready, immediately before entering the guest.
    stack=frame;
    thisArgument=object;
    // Observed CCallResult vtable slot 0: Run(param, ioFailure, call).
    return invoke(read(read(object)));
}

template<class Write32, class Read32, class Invoke>
bool bo2SteamDeliverServerEvent(uint32_t &stack, uint32_t &thisArgument,
        uint32_t object, const BO2SteamServerEvent &event, Write32 write,
        Read32 read, Invoke invoke) {
    if (event.callbackID!=101 && event.callbackID!=102 &&
        event.callbackID!=103 && event.callbackID!=115) return false;
    const bo2SteamGuest::RestoreStack restore{stack,stack};
    const uint32_t response=stack-bo2SteamGuest::responseReservation;
    write(response,event.callbackID==115 ? (event.secure ? 1u : 0u) :
                   event.callbackID==101 ? 0u : event.result);
    write(response+4,event.callbackID==102 && event.retry ? 1u : 0u);
    const uint32_t frame=response-8;
    write(frame,0xDEAD0000u);write(frame+4,response);
    stack=frame;
    thisArgument=object;
    // Observed ordinary callback slot 1: Run(param), with ret4 cleanup.
    return invoke(read(read(object)+4));
}
