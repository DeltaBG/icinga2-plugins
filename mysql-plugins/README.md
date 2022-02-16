# Icinga2 Plugins - MySQL

Source: https://github.com/lausser/check_mysql_health

# Requirements

## Debian / Ubuntu

```bash
apt install perl libdbi-perl libdbd-mysql-perl
```

## CentOS / Fedora / RHEL

```bash
yum install perl perl-Data-Dumper perl-DBI perl-DBD-MySQL
```

# Creating a database user for monitoring

```sql
GRANT USAGE ON * . * TO 'monitor'@'localhost' IDENTIFIED BY 'password';
```