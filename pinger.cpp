#include <iostream>
#include <memory>
#include <sys/types.h> 
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <thread>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <cassert>

using namespace std;
// http://stackoverflow.com/questions/13898207/recvfrom-bad-address-sendto-address-family-not-supported-by-protocol
// http://linux.die.net/man/3/setsockopt

void pinger(string msg)
{
    sockaddr_in si_me, si_other;
    int s;

    assert((s=socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP))!=-1);

    int port=4499;

    int broadcast=1;
    setsockopt(s, SOL_SOCKET, SO_BROADCAST,
                &broadcast, sizeof broadcast);

    memset(&si_me, 0, sizeof(si_me));
    si_me.sin_family = AF_INET;
    si_me.sin_port = htons(port);
    si_me.sin_addr.s_addr = inet_addr("192.168.65.255");

    unsigned char buffer[10] = "hello";
    int bytes_sent = sendto(s, buffer, sizeof(buffer), 0, (struct sockaddr*)&si_me, sizeof(si_me));
    cout << bytes_sent; 
}

int main(int argc, char *argv[]) 
{

        sockaddr_in si_me;
        unsigned char buffer[20];
        int s;

        assert((s=socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP))!=-1);

        int port=4499;
        memset(&si_me, 0, sizeof(si_me));
        si_me.sin_family = AF_INET;
        si_me.sin_port = htons(port);
        si_me.sin_addr.s_addr = inet_addr("192.168.65.255");


        if (bind(s, (struct sockaddr*)&si_me, sizeof(si_me)) == -1)
        {
            perror("Bind error");
        } 

        // Send the message after the bind     
        pinger("hello");

        socklen_t len = sizeof si_me;
        if(recvfrom(s, buffer, 20, 0, (struct sockaddr*)&si_me, &len)==-1)
            perror("recvfrom");

        cout << "\nRECEIVE" << buffer; 

        if(close(s) == -1)
            perror("close");

}   