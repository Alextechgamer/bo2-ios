#include "win32_shim.h"
#include "dw_guest_socket.h"
#ifdef BO2_DW_ACCOUNT_SESSION
#include "SteamRuntimeProvider.h"
#endif

extern "C" uint32_t win32_shim_alloc(uint32_t size, uint32_t align);

namespace {
bo2::net::SocketTable sockets;
std::atomic<uint16_t> fixturePort{0};
#ifdef BO2_DW_ACCOUNT_SESSION
std::atomic<uint64_t> launchAccount{0};
#if defined(BO2_TARGET_MPS)
constexpr uint32_t gameApp = 202990;
#elif defined(BO2_TARGET_ZMS)
constexpr uint32_t gameApp = 212910;
#else
#error Native account transport requires an explicitly supported mode
#endif
uint64_t authorizedAccount() {
    const auto provider = bo2_ios_steam_provider_snapshot();
    if (!provider.context || !provider.isLoggedOn(provider.context) ||
        !provider.ownsApp(provider.context,gameApp) || provider.vacStatus(provider.context,gameApp)!=0) return 0;
    return provider.steamID(provider.context);
}
#endif

bo2::net::Address destination(bo2::net::Address peer) {
    const auto port = fixturePort.load();
    return port ? bo2::net::Address{INADDR_LOOPBACK, port} : peer;
}

bool validBuffer(uint32_t address, uint32_t size) {
    return size == 0 || (address != 0 && size - 1 <= UINT32_MAX - address);
}

void writeAddress(uint32_t pointer, bo2::net::Address address) {
    for (unsigned i = 0; i < 16; ++i) win32_mem_write8(pointer + i, 0);
    win32_mem_write8(pointer, 2);
    win32_mem_write8(pointer + 2, address.port >> 8);
    win32_mem_write8(pointer + 3, address.port & 255);
    for (unsigned i = 0; i < 4; ++i)
        win32_mem_write8(pointer + 4 + i, address.ip >> (24 - 8 * i));
}

uint32_t transfer(State &state, bool sending, bool datagram = false) {
    const auto handle = win32_arg(state, 0);
    const auto address = win32_arg(state, 1);
    const auto length = win32_arg(state, 2);
    const auto flags = win32_arg(state, 3);
    if (length > INT_MAX || !validBuffer(address, length)) return bo2::net::fail(10014);
    // Preserve datagram boundaries. Fail an oversized allocation as WSAENOBUFS.
    if (length > 4 * 1024 * 1024) return bo2::net::fail(10055);
    const size_t count = length;
    const auto addressPointer = datagram ? win32_arg(state, 4) : 0;
    const auto addressLength = datagram ? win32_arg(state, 5) : 0;
    bo2::net::Address peer{};
    if (addressPointer && sending && !bo2::net::readGuestAddress(
            addressPointer, int32_t(addressLength), peer, win32_mem_read8))
        return UINT32_MAX;
    if (addressPointer && !sending && (!validBuffer(addressPointer, 16) ||
            !validBuffer(addressLength, 4) || int32_t(win32_mem_read32(addressLength)) < 16))
        return bo2::net::fail(10014);
    std::vector<uint8_t> buffer(count);
    if (sending) {
        for (size_t i = 0; i < count; ++i) buffer[i] = win32_mem_read8(address + i);
        if (addressPointer) return sockets.sendTo(handle, buffer.data(), count, flags, destination(peer));
        return sockets.send(handle, buffer.data(), count, flags);
    }
    const auto received = datagram ? sockets.recvFrom(handle, buffer.data(), count, flags, peer)
                                   : sockets.recv(handle, buffer.data(), count, flags);
    if (received >= 0 && addressPointer) {
        writeAddress(addressPointer, peer);
        win32_mem_write32(addressLength, 16);
    }
    for (int64_t i = 0; i < received; ++i) win32_mem_write8(address + i, buffer[i]);
    return received;
}

uint32_t selectGuest(State &state) {
    std::vector<uint32_t> sets[3];
    uint32_t pointers[3];
    for (unsigned i = 0; i < 3; ++i) {
        pointers[i] = win32_arg(state, i + 1);
        if (!pointers[i]) continue;
        if (!validBuffer(pointers[i], 4)) return bo2::net::fail(10014);
        const auto count = win32_mem_read32(pointers[i]);
        if (count > 64) return bo2::net::fail(10022);
        if (!validBuffer(pointers[i], 4 + count * 4)) return bo2::net::fail(10014);
        for (unsigned j = 0; j < count; ++j)
            sets[i].push_back(win32_mem_read32(pointers[i] + 4 + 4 * j));
    }
    int timeout = -1;
    const auto duration = win32_arg(state, 4);
    if (duration) {
        if (!validBuffer(duration, 8)) return bo2::net::fail(10014);
        const int32_t seconds = win32_mem_read32(duration);
        const int32_t micros = win32_mem_read32(duration + 4);
        if (seconds < 0 || micros < 0 || micros >= 1000000) return bo2::net::fail(10022);
        timeout = int(std::min<int64_t>(INT_MAX, int64_t(seconds) * 1000 + (micros + 999) / 1000));
    }
    const int ready = sockets.select(sets[0], sets[1], sets[2], timeout);
    if (ready < 0) return UINT32_MAX;
    for (unsigned i = 0; i < 3; ++i) {
        if (!pointers[i]) continue;
        win32_mem_write32(pointers[i], sets[i].size());
        for (unsigned j = 0; j < sets[i].size(); ++j)
            win32_mem_write32(pointers[i] + 4 + 4 * j, sets[i][j]);
    }
    return ready;
}

uint32_t resolveGuest(uint32_t namePointer) {
    if (!validBuffer(namePointer, 254)) { bo2::net::fail(10014); return 0; }
    std::string name;
    for (unsigned i = 0; i < 254; ++i) {
        char c = win32_mem_read8(namePointer + i);
        if (!c) break;
        name.push_back(c);
    }
    if (name.empty() || name.size() > 253) { bo2::net::fail(11001); return 0; }
    auto ips = fixturePort.load() ? std::vector<uint32_t>{INADDR_LOOPBACK} : sockets.resolveIPv4(name);
    if (ips.empty()) return 0;
    // Winsock keeps one hostent per calling thread, valid until its next lookup.
    static thread_local uint32_t entry = 0;
    if (!entry) entry = win32_shim_alloc(416, 4);
    if (!validBuffer(entry, 416)) { bo2::net::fail(10055); return 0; }
    const auto list = entry + 20, addresses = entry + 88, text = entry + 152;
    win32_mem_write32(entry, text);
    win32_mem_write32(entry + 4, entry + 16);
    win32_mem_write32(entry + 8, 2 | (4u << 16));
    win32_mem_write32(entry + 12, list);
    win32_mem_write32(entry + 16, 0);
    for (unsigned i = 0; i < ips.size(); ++i) {
        win32_mem_write32(list + 4 * i, addresses + 4 * i);
        for (unsigned j = 0; j < 4; ++j)
            win32_mem_write8(addresses + 4 * i + j, ips[i] >> (24 - 8 * j));
    }
    win32_mem_write32(list + 4 * ips.size(), 0);
    for (unsigned i = 0; i <= name.size(); ++i) win32_mem_write8(text + i, name.c_str()[i]);
    return entry;
}
}

// Only call this adapter after selecting native routing for the whole session.
extern "C" bool bo2_dw_set_loopback_fixture(uint16_t port) {
    uint16_t unset = 0;
    return port && fixturePort.compare_exchange_strong(unset, port);
}
#ifdef BO2_DW_ACCOUNT_SESSION
extern "C" bool bo2_dw_enable_account_transport() {
    const auto account=authorizedAccount();
    if (!account) return false;
    launchAccount.store(account);
    return true;
}
extern "C" void bo2_dw_stop_account_transport() {
    if (launchAccount.exchange(0)) std::fprintf(stderr,"[bo2-network] account transport stopped\n");
    sockets.stop();
}
#endif

// The caller supplies the actual imported function's stdcall parameter count.
void bo2_dw_online_call(State &state, unsigned ordinal, unsigned argumentCount) {
    using namespace bo2::net;
#ifdef BO2_DW_ACCOUNT_SESSION
    const auto account=launchAccount.load();
    if (!account || authorizedAccount()!=account) {
        bo2_dw_stop_account_transport();
        fail(10050);
        state.gpr.rax.dword = ordinal==52 ? 0u : ordinal==111 ? 10050u : UINT32_MAX;
        win32_stdcall_ret(state,argumentCount);
        return;
    }
#endif
    uint32_t result;
    switch (ordinal) {
    case 2:
    case 4: {
        Address peer{};
        if (!readGuestAddress(win32_arg(state, 1), int32_t(win32_arg(state, 2)), peer, win32_mem_read8))
            result = UINT32_MAX;
        else if (ordinal == 2)
            result = sockets.bind(win32_arg(state, 0), fixturePort.load() ? Address{INADDR_LOOPBACK, 0} : peer);
        else
            result = sockets.connect(win32_arg(state, 0), destination(peer));
        break;
    }
    case 3: result = sockets.close(win32_arg(state, 0)); break;
    case 6: {
        const auto pointer = win32_arg(state, 1), length = win32_arg(state, 2);
        Address bound{};
        if (!validBuffer(length, 4) || !validBuffer(pointer, 16) || int32_t(win32_mem_read32(length)) < 16)
            result = fail(10014);
        else if (sockets.localAddress(win32_arg(state, 0), bound) < 0) result = UINT32_MAX;
        else { writeAddress(pointer, bound); win32_mem_write32(length, 16); result = 0; }
        break;
    }
    case 12: {
        const auto pointer = win32_arg(state, 2);
        if (win32_arg(state, 1) != 0x8004667e) result = fail(10045);
        else if (!validBuffer(pointer, 4)) result = fail(10014);
        else result = sockets.nonblocking(win32_arg(state, 0), win32_mem_read32(pointer) != 0);
        break;
    }
    case 16: result = transfer(state, false); break;
    case 17: result = transfer(state, false, true); break;
    case 18: result = selectGuest(state); break;
    case 19: result = transfer(state, true); break;
    case 20: result = transfer(state, true, true); break;
    case 21: {
        const auto value = win32_arg(state, 3);
        if (int32_t(win32_arg(state, 4)) < 4 || !validBuffer(value, 4)) result = fail(10014);
        else result = sockets.setOption(win32_arg(state, 0), win32_arg(state, 1),
                                        win32_arg(state, 2), win32_mem_read32(value));
        break;
    }
    case 22: result = sockets.shutdown(win32_arg(state, 0), win32_arg(state, 1)); break;
    case 23: result = sockets.socket(win32_arg(state, 0), win32_arg(state, 1), win32_arg(state, 2)); break;
    case 52: result = resolveGuest(win32_arg(state, 0)); break;
    case 111: result = sockets.lastError(); break;
    case 112: socketLastError = win32_arg(state, 0); result = 0; break;
    default: result = fail(10045); break;
    }
    // Capture one result per operation and outcome. Payloads and account
    // identifiers never enter the transport log.
    static std::atomic<bool> reported[113][2]{};
    const bool failed = ordinal==52 ? result==0 : result==UINT32_MAX;
    if (ordinal < 113 && !reported[ordinal][failed].exchange(true))
        std::fprintf(stderr,"[bo2-network] ordinal=%u failed=%d error=%d\n",
                     ordinal, int(failed), failed ? sockets.lastError() : 0);
    state.gpr.rax.dword = result;
    win32_stdcall_ret(state, argumentCount);
}
