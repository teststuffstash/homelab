# Manual steps

https://github.com/linuxserver/docker-unifi-network-application?tab=readme-ov-file#device-adoption

For Unifi to adopt other devices, e.g. an Access Point, it is required to change the inform IP address. Because Unifi
runs inside Docker by default it uses an IP address not accessible by other devices. To change this go to Settings >
System > Advanced and set the Inform Host to a hostname or IP address accessible by your devices. Additionally the
checkbox "Override" has to be checked, so that devices can connect to the controller during adoption (devices use the
inform-endpoint during adoption).

