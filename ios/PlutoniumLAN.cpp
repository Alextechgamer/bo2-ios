// Private T6 r5369 LAN transport for the translated Multiplayer and Zombies clients.
#include "win32_shim.h"
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#include <array>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>

extern "C" void *pluto_original_send(State*, uint32_t, void*);
extern "C" void *pluto_original_receive(State*, uint32_t, void*);
extern "C" void *pluto_original_ui_dispatch(State*, uint32_t, void*);
extern "C" void *pluto_original_allocate(State*, uint32_t, void*);
extern "C" void *pluto_original_audio_fill(State*, uint32_t, void*);
extern "C" void *pluto_original_gamestate_long(State*, uint32_t, void*);
extern "C" void *pluto_original_client_memory(State*, uint32_t, void*);
extern "C" void *pluto_original_server_id(State*, uint32_t, void*);
extern "C" void *pluto_original_packet_event(State*, uint32_t, void*);
extern "C" void *pluto_original_lua_init(State*, uint32_t, void*);
#if BO2_PLUTONIUM_ZOMBIES
extern "C" void *sub_9664a0(State*, uint32_t, void*);
#else
extern "C" void *pluto_original_lua_read(State*, uint32_t, void*);
extern "C" void *sub_969120(State*, uint32_t, void*);
extern "C" uint32_t win32_shim_alloc(uint32_t, uint32_t);
extern "C" const uint8_t bo2_mp_lua_bytes[];
#endif

namespace {
using Packet = std::vector<uint8_t>;
enum class Phase { Idle, Settings, Rules, Mods, Challenge, Playing };
std::mutex lock;
std::atomic<Phase> phase{Phase::Idle};
int channel=-1, listener=-1;
bool usb=false, configured=false;
in_addr peerIP{};
uint16_t peerPort=0;
std::array<uint8_t,20> gamePeer{};
Packet incoming, outgoing;
Packet serverMap, nextPacket;
size_t written=0;

// Drop only the byte stream. The handshake phase and any pending map packet
// belong to the game connection, which survives a USB reconnect.
void closeChannel() {
    if(channel>=0) close(channel);
    channel=-1;
    incoming.clear();outgoing.clear();written=0;
}
bool nonblocking(int fd) {
    return fd>=0 && fcntl(fd,F_SETFL,fcntl(fd,F_GETFL,0)|O_NONBLOCK)==0;
}
bool ready() {
    if(channel>=0) return true;
    if(listener<0) return false;
    int fd=accept(listener,nullptr,nullptr);
    if(fd<0) return false;
    if(!nonblocking(fd)){close(fd);return false;}
    int yes=1;
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof yes);
    // Game packets are small and frequent. Send each at once.
    setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof yes);
    channel=fd;
    return true;
}
bool flush() {
    while(written<outgoing.size()){
        ssize_t n=send(channel,outgoing.data()+written,outgoing.size()-written,0);
        if(n<0 && errno==EINTR) continue;
        if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK)) return true;
        if(n<=0){closeChannel();return false;}
        written+=static_cast<size_t>(n);
    }
    outgoing.clear();written=0;return true;
}
bool transmit(const Packet& p) {
    if(!ready() || p.empty() || p.size()>65507) return false;
    if(!usb) return send(channel,p.data(),p.size(),0)==static_cast<ssize_t>(p.size());
    if(outgoing.size()-written+p.size()+2>1024*1024) return false;
    if(written){outgoing.erase(outgoing.begin(),outgoing.begin()+written);written=0;}
    outgoing.push_back(p.size()>>8);outgoing.push_back(static_cast<uint8_t>(p.size()));
    outgoing.insert(outgoing.end(),p.begin(),p.end());
    return flush();
}
Packet take() {
    if(!ready()) return {};
    std::array<uint8_t,65536> buffer;
    if(!usb){
        ssize_t n=recv(channel,buffer.data(),buffer.size(),0);
        return n>0?Packet(buffer.begin(),buffer.begin()+n):Packet{};
    }
    if(!flush()) return {};
    while(incoming.size()<2 || incoming.size()<2u+((incoming[0]<<8)|incoming[1])){
        ssize_t n=recv(channel,buffer.data(),buffer.size(),0);
        if(n<0 && errno==EINTR) continue;
        if(n<0 && (errno==EAGAIN || errno==EWOULDBLOCK)) return {};
        if(n<=0){closeChannel();return {};}
        incoming.insert(incoming.end(),buffer.begin(),buffer.begin()+n);
    }
    size_t len=(incoming[0]<<8)|incoming[1];
    if(!len || len>65507){closeChannel();return {};}
    Packet p(incoming.begin()+2,incoming.begin()+2+len);
    incoming.erase(incoming.begin(),incoming.begin()+2+len);
    return p;
}
std::string command(const Packet& p) {
    if(p.size()<5 || std::memcmp(p.data(),"\xff\xff\xff\xff",4)) return {};
    size_t end=4;
    while(end<p.size() && end<36 && p[end]>32 && p[end]<127) ++end;
    return std::string(p.begin()+4,p.begin()+end);
}
bool request(const std::string& cmd) {
    Packet p(4,255);p.insert(p.end(),cmd.begin(),cmd.end());return transmit(p);
}
bool readServerMap(const Packet& packet) {
    std::string text(packet.begin()+4,packet.end());
    char map[64]={},type[64]={};
    if(sscanf(text.c_str(),"connectRes \"%63[a-zA-Z0-9_]\" \"%63[a-zA-Z0-9_]\"",map,type)!=2)
        return false;
    // The retail client loads remote maps through its loadingnewmap handler.
    // Plutonium supplies these two arguments earlier, in the connectRes reply.
    std::string change=std::string("loadingnewmap\n")+map+"\n"+type;
    serverMap.assign(4,255);serverMap.insert(serverMap.end(),change.begin(),change.end());
    return true;
}
bool retry() {
    switch(phase.load()){
    case Phase::Settings:return request("connectReq");
    case Phase::Rules:return request("connectGTSReq");
    case Phase::Mods:return request("moddl_list");
    case Phase::Challenge:{
        char text[72];
        snprintf(text,sizeof text,"getchallenge %04x \"offline\" 5369",arc4random_uniform(65536));
        return request(text);
    }
    default:return false;
    }
}
void returns(State& s,uint32_t result) {s.gpr.rax.dword=result;win32_cdecl_ret(s);}

constexpr uint32_t configOffsets=BO2_PLUTONIUM_ZOMBIES?0x1131b0c:0x1133a7c;
constexpr uint32_t slotFlags=BO2_PLUTONIUM_ZOMBIES?0x10e7e10:0x10e9d80;
// A direct console join skips the lobby that marks local player slot zero
// active. Call the retail slot setter on a scratch frame below the stack.
bool activateLocalSlot(State *s,void *mem) {
    if(win32_mem_read8(slotFlags)&1) return false;
    State saved=*s;
    uint32_t sp=(s->gpr.rsp.dword&~15u)-12;
    win32_mem_write32(sp,0xdead0003);
    win32_mem_write32(sp+4,0);
    win32_mem_write32(sp+8,1);
    s->gpr.rsp.dword=sp;
#if BO2_PLUTONIUM_ZOMBIES
    sub_9664a0(s,0x9664a0,mem);
#else
    sub_969120(s,0x969120,mem);
#endif
    *s=saved;
    return win32_mem_read8(slotFlags)&1;
}
// Read argv[1] from the console connect handler's current command frame.
bool privateConnectCommand(const State& s) {
    uint32_t tls=win32_mem_read32(s.addr.fs_base.dword+0x2c);
    uint32_t index=win32_mem_read32(BO2_PLUTONIUM_ZOMBIES?0x3337df4:0x3339d74);
    if(!tls || uint64_t(tls)+uint64_t(index)*4+4>(uint64_t{1}<<32)) return false;
    uint32_t thread=win32_mem_read32(tls+index*4);
    uint32_t slots=thread?win32_mem_read32(thread+0x58):0;
    uint32_t cmd=slots?win32_mem_read32(slots+16):0;
    if(!cmd) return false;
    uint32_t level=win32_mem_read32(cmd);
    if(level>=8 || win32_mem_read32(cmd+0x84+4*level)!=2) return false;
    uint32_t argv=win32_mem_read32(cmd+0xa4+4*level);
    uint32_t arg=argv?win32_mem_read32(argv+4):0;
    char ip[INET_ADDRSTRLEN],endpoint[INET_ADDRSTRLEN+6];
    if(!arg || !inet_ntop(AF_INET,&peerIP,ip,sizeof ip)) return false;
    int n=snprintf(endpoint,sizeof endpoint,"%s:%u",ip,unsigned(peerPort));
    if(n<0 || size_t(n)>=sizeof endpoint || uint64_t(arg)+unsigned(n)>UINT32_MAX) return false;
    for(int i=0;i<=n;++i)
        if(win32_mem_read8(arg+i)!=static_cast<uint8_t>(endpoint[i])) return false;
    return true;
}

// r5369 writes NUL-terminated strings, then an empty string, after the
// gamestate checksum. The retail reader expects section 6 immediately there.
bool findSection6(uint32_t msg,uint64_t pos,uint32_t& section) {
    const uint32_t data=win32_mem_read32(msg+8),split=win32_mem_read32(msg+12);
    const uint32_t size=win32_mem_read32(msg+20),splitSize=win32_mem_read32(msg+24);
    const uint64_t end=uint64_t(size)+splitSize;
    if(win32_mem_read32(msg) || end>INT32_MAX || (size && !data) ||
       (splitSize && !split) || uint64_t(data)+size>(uint64_t{1}<<32) ||
       uint64_t(split)+splitSize>(uint64_t{1}<<32)) return false;
    auto byteAt=[&](uint32_t i) {
        return win32_mem_read8(i<size?data+i:split+(i-size));
    };
    unsigned length=0;
    while(pos<end) {
        if(byteAt(static_cast<uint32_t>(pos++))) {
            if(++length>=1024) return false;
        } else if(length) {
            length=0;
        } else {
            section=static_cast<uint32_t>(pos);
            return pos<end && byteAt(section)==6;
        }
    }
    return false;
}

// T6 HavokScript stores a hash mask and 16-byte key/value nodes at +12/+16.
// Only the per-frame pump may be skipped while the requested root is absent.
// Other event types, including errors, follow the original engine path.
struct Member {
    bool inspected;
    uint32_t tag;
    uint32_t value;
};
Member tableValue(uint32_t table,const char *key) {
    uint32_t mask=win32_mem_read32(table+12),nodes=win32_mem_read32(table+16);
    if(!nodes || mask>=65536) return {false,0,0};
    size_t len=strlen(key);
    for(uint32_t j=0;j<=mask;j++){
        uint32_t entry=nodes+16*j;
        if((win32_mem_read32(entry)&15)!=4) continue;
        uint32_t str=win32_mem_read32(entry+4);
        if(!str || (win32_mem_read32(str+4)&0x3fffffff)!=len) continue;
        const auto *bytes=win32_guest_ptr(str+12);
        if(bytes && !memcmp(bytes,key,len))
            return {true,win32_mem_read32(entry+8)&15,win32_mem_read32(entry+12)};
    }
    return {true,0,0};
}
}

extern "C" bool bo2_pluto_start(const char *ip,uint16_t port,bool useUSB) {
    std::lock_guard<std::mutex> guard(lock);
    if(configured || !ip || !port || inet_pton(AF_INET,ip,&peerIP)!=1) return false;
    peerPort=port;usb=useUSB;
    sockaddr_in addr{};addr.sin_family=AF_INET;addr.sin_len=sizeof(addr);
    int fd=socket(AF_INET,useUSB?SOCK_STREAM:SOCK_DGRAM,0);
    if(!nonblocking(fd)){if(fd>=0)close(fd);return false;}
    if(useUSB){
        addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);addr.sin_port=htons(19470);
        int yes=1;
        setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof yes);
        if(bind(fd,(sockaddr*)&addr,sizeof(addr)) || listen(fd,1)){close(fd);return false;}
        listener=fd;
    }else{
        addr.sin_addr=peerIP;addr.sin_port=htons(port);
        if(connect(fd,(sockaddr*)&addr,sizeof(addr))){close(fd);return false;}
        channel=fd;
    }
    configured=true;return true;
}

extern "C" void *bo2_pluto_send(State *s,uint32_t pc,void *mem){
    uint32_t addr=s->gpr.rsp.dword+16;
    if(!configured || win32_mem_read32(addr)!=peerIP.s_addr ||
       (win32_mem_read32(addr+4)&65535)!=peerPort || win32_mem_read32(addr+8)!=4)
        return pluto_original_send(s,pc,mem);
    std::lock_guard<std::mutex> guard(lock);
    uint32_t n=win32_arg(*s,1),ptr=win32_arg(*s,2);
    if(!n || n>65507 || uint64_t(ptr)+n>UINT32_MAX){returns(*s,0);return mem;}
    Packet p(n);
    for(uint32_t j=0;j<n;j++) p[j]=win32_mem_read8(ptr+j);
    std::string tag=command(p);
    bool ok;
    if(tag=="getchallenge"){
        for(size_t j=0;j<gamePeer.size();j++)gamePeer[j]=win32_mem_read8(addr+j);
        if(phase==Phase::Idle || phase==Phase::Playing){
            // A new connection attempt must not inherit the last one's map packet.
            serverMap.clear();nextPacket.clear();
            phase=Phase::Settings;
        }
        ok=retry();
    }else {
#if BO2_PLUTONIUM_ZOMBIES
        // The r5369 TranZit LAN server uses 2089. Only translate the retail
        // protocol field inside the quoted connect userinfo, never binary data.
        if(tag=="connect"){
            const std::string retail="\\protocol\\2091";
            std::string text(p.begin()+4,p.end());
            auto begin=text.find('"');
            auto end=begin==text.npos?text.npos:text.find('"',begin+1);
            auto field=begin==text.npos?text.npos:text.find(retail,begin+1);
            if(end!=text.npos && field<end && field+retail.size()<=end &&
               (field+retail.size()==end || text[field+retail.size()]=='\\')){
                size_t offset=4+field+retail.size()-4;
                memcpy(p.data()+offset,"2089",4);
            }
        }
#endif
        ok=transmit(p);
    }
    if(!tag.empty())fprintf(stderr,"[Plutonium LAN] send %s %u bytes\n",tag.c_str(),n);
    returns(*s,ok);return mem;
}

extern "C" void *bo2_pluto_receive(State *s,uint32_t pc,void *mem){
    if(!configured) return pluto_original_receive(s,pc,mem);
    Packet p;
    std::array<uint8_t,20> sender;
    {
        std::lock_guard<std::mutex> guard(lock);
        if(nextPacket.empty()) p=take(); else p.swap(nextPacket);
        sender=gamePeer;
        std::string tag=command(p);
        if(!tag.empty())fprintf(stderr,"[Plutonium LAN] receive %s %zu bytes\n",tag.c_str(),p.size());
        if((phase==Phase::Settings && tag=="connectRes" && readServerMap(p)) ||
           (phase==Phase::Rules && tag=="connectGTSRes") ||
           (phase==Phase::Mods && tag=="moddl_list_r")){
            phase=phase==Phase::Settings?Phase::Rules:phase==Phase::Rules?Phase::Mods:Phase::Challenge;
            retry();p.clear();
        }else if(phase==Phase::Challenge && tag=="challengeResponse") phase=Phase::Playing;
        // Loading the world blocks the retail client's stat upload. The server
        // sends statresponse once it has accepted the player's stats.
        else if(phase==Phase::Playing && tag=="statresponse" && !serverMap.empty())
            nextPacket.swap(serverMap);
    }
    if(p.empty()) return pluto_original_receive(s,pc,mem);
    uint32_t from=win32_arg(*s,0),msg=win32_arg(*s,1);
    uint32_t dest=win32_mem_read32(msg+8);
    if(p.size()>=win32_mem_read32(msg+16) || uint64_t(dest)+p.size()>UINT32_MAX){
        returns(*s,0);return mem;
    }
    for(size_t i=0;i<p.size();i++)win32_mem_write8(dest+i,p[i]);
    for(size_t i=0;i<sender.size();i++)win32_mem_write8(from+i,sender[i]);
    win32_mem_write32(msg+20,p.size());win32_mem_write32(msg+28,0);win32_mem_write32(msg+44,0);
    returns(*s,1);return mem;
}

extern "C" void *bo2_pluto_allocate(State *s,uint32_t pc,void *mem){
    // The first world allocation after a private join can run after ParseGamestate.
    // Flag 4 asks the original allocator to retain the populated configstrings.
    constexpr uint32_t caller=BO2_PLUTONIUM_ZOMBIES?0x556bbe:0x554bde;
    constexpr uint32_t strings=configOffsets+0x57b0;
    uint32_t sp=s->gpr.rsp.dword;
    if(configured && phase==Phase::Playing && win32_mem_read32(sp)==caller &&
       win32_mem_read32(sp+16)==2){
        uint32_t entry=win32_mem_read32(configOffsets+8);
        if(entry && entry<=0x10000-4 && win32_mem_read32(strings+entry)==0x00646f63)
            win32_mem_write32(sp+16,6);
    }
    return pluto_original_allocate(s,pc,mem);
}

extern "C" void *bo2_pluto_server_id(State *s,uint32_t pc,void *mem){
    constexpr uint32_t mapInitCaller=BO2_PLUTONIUM_ZOMBIES?0x4d95df:0x4d7f2f;
    constexpr uint32_t state=BO2_PLUTONIUM_ZOMBIES?0x10e7e18:0x10e9d88;
    if(configured && phase==Phase::Playing && win32_mem_read32(s->gpr.rsp.dword)==mapInitCaller &&
       win32_arg(*s,0)==0 && win32_mem_read32(state)==8){
        // CG_Init rereads configstring 3 after the map has cleared it. Keep
        // the ID that CL_ParseGamestate already parsed for this connection.
        uint32_t active=win32_mem_read32(BO2_PLUTONIUM_ZOMBIES?0x10e8344:0x10ea2b4);
        uint32_t id=win32_mem_read32(BO2_PLUTONIUM_ZOMBIES?0x10f109c:0x10f300c);
        uint32_t offset=win32_mem_read32(configOffsets+12);
        if(active && id && id<=UINT8_MAX && win32_mem_read32(active+0x2abc)==id &&
           offset<0x10000 && !win32_mem_read8(configOffsets+0x57b0+offset)){
            returns(*s,id);
            fprintf(stderr,"[Plutonium LAN] retained gamestate server ID %u during CG_Init\n",id);
            return mem;
        }
    }
    return pluto_original_server_id(s,pc,mem);
}

extern "C" void *bo2_pluto_client_memory(State *s,uint32_t pc,void *mem){
    uint32_t sp=s->gpr.rsp.dword;
    constexpr uint32_t connectCaller=BO2_PLUTONIUM_ZOMBIES?0x556f3c:0x554ffc;
    if(configured && win32_mem_read32(sp)==connectCaller && win32_arg(*s,1)==3 &&
       privateConnectCommand(*s)){
        // CL_InitCGame requests layout 2. Allocate it before connecting so
        // that its later call reuses the live netchan and snapshot buffers.
        win32_mem_write32(sp+8,2);
        fprintf(stderr,"[Plutonium LAN] requested map client memory before connect\n");
    }
    return pluto_original_client_memory(s,pc,mem);
}

extern "C" void *bo2_pluto_packet_event(State *s,uint32_t pc,void *mem){
    uint32_t peer=s->gpr.rsp.dword+8;
    if(!configured || phase!=Phase::Playing || win32_mem_read32(peer)!=peerIP.s_addr ||
       (win32_mem_read32(peer+4)&65535)!=peerPort || win32_arg(*s,0)!=0)
        return pluto_original_packet_event(s,pc,mem);
    constexpr uint32_t connection=BO2_PLUTONIUM_ZOMBIES?0x10e8348:0x10ea2b8;
    constexpr uint32_t realtime=BO2_PLUTONIUM_ZOMBIES?0x10e84b0:0x10ea420;
    uint32_t conn=win32_mem_read32(connection);
    uint32_t sequence=conn?win32_mem_read32(conn+0x4340):0;
    void *result=pluto_original_packet_event(s,pc,mem);
    // In the map-init checksum fallback the retail dispatcher stops updating
    // lastPacketTime. Refresh it only when the original netchan accepts and
    // parses a new server message. Lost or rejected packets still time out.
    if((s->gpr.rax.dword & 255) && conn && conn==win32_mem_read32(connection) &&
       win32_mem_read32(conn+0x4340)!=sequence){
        if(win32_mem_read8(conn+0x2434f))
            win32_mem_write32(conn+0xc,win32_mem_read32(realtime));
#if !BO2_PLUTONIUM_ZOMBIES
        // A direct console join can enter CA_ACTIVE without the lobby having
        // activated slot zero. GetLocalPlayers then omits its valid entity.
        // Normally done before the in-game UI starts; this is the late fallback.
        if(win32_mem_read32(0x10e9d88)==10 && activateLocalSlot(s,mem))
            fprintf(stderr,"[Plutonium LAN] activated MP local player slot late\n");
#endif
    }
    return result;
}

extern "C" void *bo2_pluto_gamestate_long(State *s,uint32_t pc,void *mem){
    uint32_t caller=win32_mem_read32(s->gpr.rsp.dword);
    constexpr uint32_t clientNumber=BO2_PLUTONIUM_ZOMBIES?0x559a24:0x558a54;
    constexpr uint32_t checksum=BO2_PLUTONIUM_ZOMBIES?0x559a41:0x558a71;
    if(!configured || phase!=Phase::Playing || (caller!=clientNumber && caller!=checksum))
        return pluto_original_gamestate_long(s,pc,mem);
    uint32_t msg=win32_arg(*s,0);
    void *result=pluto_original_gamestate_long(s,pc,mem);
    uint32_t section=0;
    uint64_t pos=win32_mem_read32(msg+28);
    // Validate while the caller can still reject the entire gamestate using
    // its invalid-client-number path, before entering either section reader.
    if(!findSection6(msg,pos+(caller==clientNumber?4:0),section)) {
        win32_mem_write32(msg,1);
        s->gpr.rax.dword=UINT32_MAX;
    } else if(caller==checksum) {
        win32_mem_write32(msg+28,section);
        fprintf(stderr,"[Plutonium LAN] gamestate string list %u bytes, section 6 at %u\n",
                section-static_cast<uint32_t>(pos),section);
    }
    return result;
}

extern "C" void *bo2_pluto_audio_fill(State *s,uint32_t pc,void *mem){
    if(configured && phase==Phase::Playing && win32_arg(*s,0)){
        // The codec divides the sample buffer size by the source channel count.
        // A source with no channels cannot fill the buffer this iteration.
        uint32_t source=win32_arg(*s,1);
        uint32_t bank=source?win32_mem_read32(source+0x18):0;
        uint32_t format=bank?win32_mem_read32(bank+0x64):0;
        uint32_t channels=bank?(format?win32_mem_read8(format+0x11):0):
                               (source?win32_mem_read32(source+4):0);
        if(!channels){returns(*s,0);return mem;}
    }
    return pluto_original_audio_fill(s,pc,mem);
}

extern "C" void *bo2_pluto_lua_init(State *s,uint32_t pc,void *mem){
    if(configured && phase==Phase::Playing){
        // A private join reaches this call asking for the frontend UI. Select
        // the in-game initializer while the client is connecting or loading.
        uint32_t sp=s->gpr.rsp.dword;
        if(win32_mem_read32(sp)==(BO2_PLUTONIUM_ZOMBIES?0x55d38f:0x55c04f) && win32_arg(*s,0)==1){
            uint32_t state=win32_mem_read32(BO2_PLUTONIUM_ZOMBIES?0x10e7e18:0x10e9d88);
            if(state>=6 && state<=9) win32_mem_write32(sp+4,0);
        }
        // The in-game initializer creates the player's UI root and adds the
        // HUD menu only while local player slot zero is active.
        if(!(win32_arg(*s,0)&255) && activateLocalSlot(s,mem))
            fprintf(stderr,"[Plutonium LAN] activated local player slot before in-game UI init\n");
    }
    return pluto_original_lua_init(s,pc,mem);
}

#if !BO2_PLUTONIUM_ZOMBIES

extern "C" void *bo2_pluto_lua_read(State *s,uint32_t pc,void *mem){
    struct Script { const char *name; uint32_t offset,size,compiledSize,rawfile; };
    static Script scripts[]={
#include "mp-lua.inc"
    };
    static std::mutex scriptMutex;
    uint32_t raw=win32_arg(*s,1),sizeOut=win32_arg(*s,2);
    if(configured && phase==Phase::Playing && raw && win32_mem_read32(raw+4)){
        const char *name=reinterpret_cast<const char*>(win32_guest_ptr(win32_mem_read32(raw)));
        for(auto& script:scripts){
            if(!name || strcmp(name,script.name)) continue;
            std::lock_guard<std::mutex> guard(scriptMutex);
            if(!script.rawfile){
                uint32_t nameSize=static_cast<uint32_t>(strlen(script.name))+1;
                uint32_t payload=script.size+script.compiledSize;
                uint32_t record=win32_shim_alloc(12+payload+nameSize,4);
                if(!record) break;
                uint32_t bytes=record+12,guestName=bytes+payload;
                memcpy(win32_guest_ptr(bytes),bo2_mp_lua_bytes+script.offset,payload);
                memcpy(win32_guest_ptr(guestName),script.name,nameSize);
                win32_mem_write32(record,guestName);
                win32_mem_write32(record+4,script.size);
                win32_mem_write32(record+8,bytes);
                script.rawfile=record;
            }
            win32_mem_write32(s->gpr.rsp.dword+8,script.rawfile);
            // Retail hashes the original file. Give the VM the compiled form
            // of that same file, as its retail assets use T6 bytecode.
            void *result=pluto_original_lua_read(s,pc,mem);
            if(s->gpr.rax.dword && sizeOut){
                s->gpr.rax.dword=script.rawfile+12+script.size;
                win32_mem_write32(sizeOut,script.compiledSize);
            }
            return result;
        }
    }
    return pluto_original_lua_read(s,pc,mem);
}
#endif

extern "C" void *bo2_pluto_ui_dispatch(State *s,uint32_t pc,void *mem){
    if(configured && phase!=Phase::Idle){
        const char *event=(const char*)win32_guest_ptr(win32_arg(*s,1));
        const char *root=(const char*)win32_guest_ptr(win32_arg(*s,0));
        uint32_t vm=win32_arg(*s,2);
        if(vm && event && root && !strcmp(event,"process_events") && !strcmp(root,"UIRoot0")){
            uint32_t env=win32_mem_read32(vm+0x3c);
            Member lui=env?tableValue(env,"LUI"):Member{false,0,0};
            Member roots=lui.tag==5?tableValue(lui.value,"roots"):Member{lui.inspected && !lui.tag,0,0};
            Member target=roots.tag==5?tableValue(roots.value,root):Member{roots.inspected && !roots.tag,0,0};
            static unsigned observations=0;
            if(observations++<4) fprintf(stderr,"[Plutonium LAN] UI dispatch %s, tags %u/%u/%u (resolved %d)\n",root,lui.tag,roots.tag,target.tag,target.inspected);
            if(target.inspected && !target.tag){returns(*s,0);return mem;}
        }
    }
    return pluto_original_ui_dispatch(s,pc,mem);
}
