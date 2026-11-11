// Native socket mechanics only. No game-service replies or security results.
#pragma once
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

namespace bo2::net {
inline bool onlineSelected(const char *value) { return value && std::strcmp(value,"online")==0; }
inline thread_local int socketLastError=0;
inline int fail(int error) { socketLastError=error;return -1; }
inline int windowsError(int e) {
    if(e==EAGAIN || e==EWOULDBLOCK || e==EINPROGRESS)return 10035;
    switch(e){
    case 0:return 0;case EINTR:return 10004;case EACCES:return 10013;case EFAULT:return 10014;
    case EINVAL:return 10022;case EMFILE:return 10024;case EALREADY:return 10037;
    case EBADF:case ENOTSOCK:return 10038;case EDESTADDRREQ:return 10039;case EMSGSIZE:return 10040;
    case EPROTOTYPE:return 10041;case ENOPROTOOPT:return 10042;case EPROTONOSUPPORT:return 10043;
    case ESOCKTNOSUPPORT:return 10044;case EOPNOTSUPP:return 10045;case EAFNOSUPPORT:return 10047;
    case EADDRINUSE:return 10048;case EADDRNOTAVAIL:return 10049;case ENETDOWN:return 10050;
    case ENETUNREACH:return 10051;case ENETRESET:return 10052;case ECONNABORTED:return 10053;
    case ECONNRESET:return 10054;case ENOMEM:case ENOBUFS:return 10055;case EISCONN:return 10056;
    case ENOTCONN:return 10057;case ESHUTDOWN:return 10058;case ETIMEDOUT:return 10060;
    case ECONNREFUSED:return 10061;case EHOSTDOWN:return 10064;case EHOSTUNREACH:return 10065;
    default:return 10022;
    }
}
struct Address { uint32_t ip;uint16_t port; };
inline sockaddr_in nativeAddress(Address a) {
    sockaddr_in sa{};sa.sin_family=AF_INET;sa.sin_addr.s_addr=htonl(a.ip);sa.sin_port=htons(a.port);
    return sa;
}

class SocketTable {
    using Clock=std::chrono::steady_clock;
    struct Socket {
        const int fd;
        const int type;
        std::atomic<bool> closed{false}, nonblocking{false};
        std::atomic<int> receiveTimeout{0}, sendTimeout{0};
        std::mutex state;
        bool connecting=false, failed=false;
        int connectError=0;
        Socket(int fd,int type):fd(fd),type(type){}
        ~Socket(){::close(fd);}
    };
    std::mutex mutex;
    std::map<uint32_t,std::shared_ptr<Socket>> sockets;
    uint32_t next=0x20000;
    bool stopped=false;

    std::shared_ptr<Socket> get(uint32_t id) {
        std::lock_guard<std::mutex> lock(mutex);
        auto it=sockets.find(id);
        if(it==sockets.end()){fail(10038);return {};}
        return it->second;
    }
    static int nativeFailure(){return fail(windowsError(errno));}
    static int flags(int value,bool receiving) {
        // MSG_WAITALL is not captured; do not silently claim it while native
        // descriptors are nonblocking and may return a short read.
        const int allowed=receiving ? 1|2 : 1|4;
        if(value & ~allowed)return fail(10045);
        return ((value&1)?MSG_OOB:0)|((value&2)?MSG_PEEK:0)|
               ((!receiving && (value&4))?MSG_DONTROUTE:0);
    }
    // Descriptors are always native-nonblocking. Emulated blocking waits release
    // the table mutex and recheck close, so another worker can cancel them.
    static int wait(const std::shared_ptr<Socket> &s,short events,int timeout) {
        const auto start=Clock::now();
        for(;;){
            if(s->closed)return fail(10038);
            int period=25;
            if(timeout>0){
                auto left=timeout-std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now()-start).count();
                if(left<=0)return fail(10060);
                period=std::min<int64_t>(period,left);
            }
            pollfd fd{s->fd,events,0};int result=::poll(&fd,1,period);
            if(result>0)return 0;
            if(result<0 && errno!=EINTR)return nativeFailure();
        }
    }
    static int completeConnect(const std::shared_ptr<Socket> &s) {
        std::lock_guard<std::mutex> lock(s->state);
        if(s->connecting){
            int error=0;socklen_t size=sizeof(error);
            if(::getsockopt(s->fd,SOL_SOCKET,SO_ERROR,&error,&size)<0)error=errno;
            s->connecting=false;s->connectError=windowsError(error);s->failed=error!=0;
        }
        return s->connectError;
    }
public:
    void stop() {
        std::map<uint32_t,std::shared_ptr<Socket>> active;
        {
            std::lock_guard<std::mutex> lock(mutex);
            stopped=true;
            active.swap(sockets);
            for (auto &item : active) item.second->closed=true;
        }
        for (auto &item : active) ::shutdown(item.second->fd,SHUT_RDWR);
    }
    int lastError()const{return socketLastError;}
    uint32_t socket(int family,int type,int protocol) {
        if(family!=2){fail(10047);return UINT32_MAX;}
        if(type!=1 && type!=2){fail(10044);return UINT32_MAX;}
        if(protocol!=0 && protocol!=(type==1?6:17)){fail(10043);return UINT32_MAX;}
        std::lock_guard<std::mutex> lock(mutex);
        if(stopped){fail(10050);return UINT32_MAX;}
        if(sockets.size()>=128 || next==UINT32_MAX){fail(10055);return UINT32_MAX;}
        int fd=::socket(AF_INET,type==1?SOCK_STREAM:SOCK_DGRAM,protocol);
        if(fd<0){nativeFailure();return UINT32_MAX;}
        if(::fcntl(fd,F_SETFL,O_NONBLOCK)<0){int error=errno;::close(fd);fail(windowsError(error));return UINT32_MAX;}
#ifdef SO_NOSIGPIPE
        int one=1;::setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
        const auto id=next++;sockets[id]=std::make_shared<Socket>(fd,type);return id;
    }
    int close(uint32_t id) {
        std::shared_ptr<Socket> s;
        {std::lock_guard<std::mutex> lock(mutex);auto it=sockets.find(id);
         if(it==sockets.end())return fail(10038);s=it->second;sockets.erase(it);}
        s->closed=true;::shutdown(s->fd,SHUT_RDWR);return 0;
    }
    int nonblocking(uint32_t id,bool enabled) {
        auto s=get(id);if(!s)return -1;s->nonblocking=enabled;return 0;
    }
    int bind(uint32_t id,Address address) {
        auto s=get(id);if(!s)return -1;auto sa=nativeAddress(address);
        return ::bind(s->fd,(sockaddr*)&sa,sizeof(sa))<0 ? nativeFailure():0;
    }
    int connect(uint32_t id,Address address) {
        auto s=get(id);if(!s)return -1;auto sa=nativeAddress(address);
        int result;
        {std::lock_guard<std::mutex> lock(s->state);
         result=::connect(s->fd,(sockaddr*)&sa,sizeof(sa));
         if(result==0){s->connecting=false;s->failed=false;s->connectError=0;return 0;}
         if(errno!=EINPROGRESS && errno!=EWOULDBLOCK)return nativeFailure();
         s->connecting=true;s->failed=false;s->connectError=0;}
        if(s->nonblocking)return fail(10035);
        if(wait(s,POLLOUT,s->sendTimeout)<0)return -1;
        int error=completeConnect(s);return error?fail(error):0;
    }
    int socketError(uint32_t id) {
        auto s=get(id);if(!s)return -1;
        std::lock_guard<std::mutex> lock(s->state);
        if(s->connectError){int error=s->connectError;s->connectError=0;return error;}
        int error=0;socklen_t size=sizeof(error);
        return ::getsockopt(s->fd,SOL_SOCKET,SO_ERROR,&error,&size)<0 ? nativeFailure():windowsError(error);
    }
    int shutdown(uint32_t id,int how) {
        auto s=get(id);if(!s)return -1;if(how<0 || how>2)return fail(10022);
        return ::shutdown(s->fd,how)<0?nativeFailure():0;
    }
    int localAddress(uint32_t id,Address &address) {
        auto s=get(id);if(!s)return -1;sockaddr_in sa{};socklen_t size=sizeof(sa);
        if(::getsockname(s->fd,(sockaddr*)&sa,&size)<0)return nativeFailure();
        address={ntohl(sa.sin_addr.s_addr),ntohs(sa.sin_port)};return 0;
    }
    int setOption(uint32_t id,int level,int option,uint32_t value) {
        auto s=get(id);if(!s)return -1;
        if(level==0xffff && (option==0x1005 || option==0x1006)){
            if(value>INT_MAX)return fail(10022);
            (option==0x1005?s->sendTimeout:s->receiveTimeout).store(value);return 0;
        }
        int nativeLevel=level==0xffff?SOL_SOCKET:level,nativeOption=0;
        if(level==0xffff){
            switch(option){case 4:nativeOption=SO_REUSEADDR;break;case 0x20:nativeOption=SO_BROADCAST;break;
            case 0x1001:nativeOption=SO_SNDBUF;break;case 0x1002:nativeOption=SO_RCVBUF;break;default:return fail(10042);}
        }else if(level==6 && option==1){nativeOption=TCP_NODELAY;}
        else return fail(10042);
        return ::setsockopt(s->fd,nativeLevel,nativeOption,&value,sizeof(value))<0?nativeFailure():0;
    }
    int64_t send(uint32_t id,const void *bytes,size_t size,int guestFlags) {
        auto s=get(id);if(!s)return -1;int f=flags(guestFlags,false);if(f<0)return -1;
        for(;;){
            if(s->closed)return fail(10038);
            auto n=::send(s->fd,bytes,size,f);if(n>=0)return n;
            if((errno!=EAGAIN && errno!=EWOULDBLOCK)||s->nonblocking)return nativeFailure();
            if(wait(s,POLLOUT,s->sendTimeout)<0)return -1;
        }
    }
    int64_t recv(uint32_t id,void *bytes,size_t size,int guestFlags) {
        auto s=get(id);if(!s)return -1;int f=flags(guestFlags,true);if(f<0)return -1;
        for(;;){
            if(s->closed)return fail(10038);
            auto n=::recv(s->fd,bytes,size,f);if(n>=0)return n;
            if((errno!=EAGAIN && errno!=EWOULDBLOCK)||s->nonblocking)return nativeFailure();
            if(wait(s,POLLIN,s->receiveTimeout)<0)return -1;
        }
    }
    int64_t sendTo(uint32_t id,const void *bytes,size_t size,int guestFlags,Address address) {
        auto s=get(id);if(!s)return -1;int f=flags(guestFlags,false);if(f<0)return -1;auto sa=nativeAddress(address);
        for(;;){
            if(s->closed)return fail(10038);
            auto n=::sendto(s->fd,bytes,size,f,(sockaddr*)&sa,sizeof(sa));if(n>=0)return n;
            if((errno!=EAGAIN && errno!=EWOULDBLOCK)||s->nonblocking)return nativeFailure();
            if(wait(s,POLLOUT,s->sendTimeout)<0)return -1;
        }
    }
    int64_t recvFrom(uint32_t id,void *bytes,size_t size,int guestFlags,Address &address) {
        auto s=get(id);if(!s)return -1;int f=flags(guestFlags,true);if(f<0)return -1;
        for(;;){
            if(s->closed)return fail(10038);
            sockaddr_in sa{};iovec vector{bytes,size};msghdr msg{};
            msg.msg_name=&sa;msg.msg_namelen=sizeof(sa);msg.msg_iov=&vector;msg.msg_iovlen=1;
            auto n=::recvmsg(s->fd,&msg,f);
            if(n>=0){address={ntohl(sa.sin_addr.s_addr),ntohs(sa.sin_port)};
                return msg.msg_flags&MSG_TRUNC?fail(10040):n;}
            if((errno!=EAGAIN && errno!=EWOULDBLOCK)||s->nonblocking)return nativeFailure();
            if(wait(s,POLLIN,s->receiveTimeout)<0)return -1;
        }
    }
    int select(std::vector<uint32_t>& read,std::vector<uint32_t>& write,std::vector<uint32_t>& except,int timeoutMS) {
        if(read.size()>64 || write.size()>64 || except.size()>64 || timeoutMS< -1)return fail(10022);
        std::map<uint32_t,std::shared_ptr<Socket>> held;
        for(auto *set:{&read,&write,&except})for(auto id:*set){auto s=get(id);if(!s)return -1;held[id]=s;}
        if(held.empty())return fail(10022);
        auto contains=[](const std::vector<uint32_t> &v,uint32_t id){return std::find(v.begin(),v.end(),id)!=v.end();};
        std::vector<pollfd> pollfds;
        for(auto &[id,s]:held){short wanted=0;
            if(contains(read,id))wanted|=POLLIN;
            if(contains(write,id))wanted|=POLLOUT;
            if(contains(except,id))wanted|=POLLPRI;
            {std::lock_guard<std::mutex> lock(s->state);if(s->connecting)wanted|=POLLOUT;}
            pollfds.push_back({s->fd,wanted,0});}
        auto start=Clock::now();
        for(;;){
            for(auto &[id,s]:held)if(s->closed)return fail(10038);
            int period=25;
            if(timeoutMS>=0){auto elapsed=std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now()-start).count();
                period=std::max<int64_t>(0,std::min<int64_t>(25,int64_t(timeoutMS)-elapsed));}
            int count=::poll(pollfds.data(),pollfds.size(),period);
            if(count<0){if(errno==EINTR)continue;return nativeFailure();}
            size_t i=0;std::vector<uint32_t> readyRead,readyWrite,readyExcept;
            for(auto &[id,s]:held){auto &polled=pollfds[i++];auto events=polled.revents;
                if(s->closed)return fail(10038);
                if(events&POLLNVAL)return fail(10038);
                if(events&(POLLOUT|POLLERR|POLLHUP))completeConnect(s);
                bool failed;{std::lock_guard<std::mutex> lock(s->state);failed=s->failed;
                    if(!s->connecting && !contains(write,id))polled.events &= ~POLLOUT;}
                if(contains(read,id) && events&(POLLIN|POLLHUP))readyRead.push_back(id);
                if(contains(write,id) && !failed && events&POLLOUT)readyWrite.push_back(id);
                if(contains(except,id) && (failed || events&POLLPRI))readyExcept.push_back(id);
            }
            int ready=readyRead.size()+readyWrite.size()+readyExcept.size();
            bool expired=timeoutMS>=0 && std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now()-start).count()>=timeoutMS;
            if(ready || expired){read=readyRead;write=readyWrite;except=readyExcept;return ready;}
        }
    }
    std::vector<uint32_t> resolveIPv4(const std::string &name) {
        if(name.empty() || name.size()>253 || name.find('\0')!=std::string::npos){fail(11001);return {};}
        addrinfo hints{};hints.ai_family=AF_INET;hints.ai_socktype=SOCK_STREAM;
        addrinfo *result=nullptr;int code=::getaddrinfo(name.c_str(),nullptr,&hints,&result);
        if(code){fail(code==EAI_AGAIN?11002:11001);return {};}
        std::vector<uint32_t> addresses;
        for(auto p=result;p && addresses.size()<16;p=p->ai_next){auto sa=(sockaddr_in*)p->ai_addr;
            auto ip=ntohl(sa->sin_addr.s_addr);if(std::find(addresses.begin(),addresses.end(),ip)==addresses.end())addresses.push_back(ip);}
        ::freeaddrinfo(result);if(addresses.empty())fail(11001);return addresses;
    }
};
}
