# homelab

## Bare metal

| Name                    | Primary use case                  |               CPU               | RAM |              Storage | Free RAM slots |
|-------------------------|:----------------------------------|:-------------------------------:|----:|---------------------:|---------------:|
| Lenovo T61 laptop       | Netboot.xyz, cloud-init, ubiquiti | 2 Cores, Intel Core™2 Duo T7300 | 4GB |                120GB |              0 |
| Raspberry PI 3B         | octopi                            |                                 |     |             16GB USB |              0 |
| Big Data, HP desktop    | opnsense                          |        4 cores,  i5-2500        | 8GB |                250GB |         2 DDR3 |
| Lenove ThinkCentre Edge | ?                                 |                                 | 4GB | 120BG + 2x16B optane |         0 DDR3 |

# Services

| Tables            |         WAN         |                      LAN |                                   UI |
|-------------------|:-------------------:|-------------------------:|-------------------------------------:|
| Telia             |     192.168.1.1     |                          |                   http://192.168.1.1 |
| octopi            |                     |                          |                  http://octopi.local |
| OPNsense          | https://192.168.2.1 |      https://192.168.2.1 |       https://opnsense.teststuff.net |
| rancher dashboard |      TODO: T61      |                TODO: T61 |                                   $1 |
| netboot.xyz       |                     | http://192.168.2.2:3000/ |                                      |
| Ubiquity          |                     |                          | https://ubiquiti.teststuff.net:8443/ |

pfsense

Netboot on physiucal machine, set rocky kickstart url:
http://192.168.2.2:8000/r9.ks
http://192.168.2.2:8000/Rocky-9-GenericCloud-Base.ks
Rocky-9-GenericCloud.ks

Turn off display on laptops(console physically on machine):
setterm -blank n

Permanent:
setterm -blank 1 >> /etc/issue