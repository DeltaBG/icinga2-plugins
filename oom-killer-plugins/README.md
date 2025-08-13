# Enable dmesg: read kernel buffer

## Temporary change

```txt
sysctl --write kernel.dmesg_restrict=0
```

## Persistant change

- Create file `/etc/sysctl.d/999-nagios.conf` with conten

```text
kernel.dmesg_restrict=0
```

```bash
sysctl --system
```
