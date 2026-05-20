
```shell
ansible-playbook -i homelab --limit 192.168.2.11 sudoers.yml -b -K
```

```shell
ansible-playbook -i homelab site.yml --become
```


# Snap in docker limitations
https://github.com/canonical/docker-snap
Docker should function normally, with the following caveats:

All files that docker needs access to should live within your $HOME folder.

If you are using Ubuntu Core 16, you'll need to work within a subfolder of $HOME that is readable by root; see #8.
Additional certificates used by the Docker daemon to authenticate with registries need to be located in /var/snap/docker/common/etc/certs.d instead of /etc/docker/certs.d.

Specifying the option --security-opt="no-new-privileges=true" with the docker run command (or the equivalent in docker-compose) will result in a failure of the container to start. This is due to an an underlying external constraint on AppArmor; see LP#1908448 for details.
