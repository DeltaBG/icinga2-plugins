# OpenStack plugins

## check_openstack_rabbitmq_rpc_queues.py

Read-only check of the OpenStack RPC queues in RabbitMQ: does every nova-compute and
neutron-openvswitch-agent process on a compute host still have its reply, host and fanout
queues? Python 3.8+, stdlib only, no files written.

It runs four `docker exec <container> rabbitmqctl -q ...` calls (`list_connections`,
`list_channels`, `list_queues`, `list_consumers`), maps each consumer to host IP and agent
process, and derives the compute host name from consumed `*.compute-N.*` queues. Processes
without such a queue (controllers) are not checked. Every node sees the whole cluster, so one
controller is enough.

Generic RabbitMQ checks (queue backlog, cluster, alarms) are covered by the upstream Perl plugins
in [`rabbitmq-plugins/`](../rabbitmq-plugins/), not here.

### Flags

| Flag            | Meaning                                                                    | State    |
|-----------------|----------------------------------------------------------------------------|----------|
| `NO-REPLY`      | process consumes no `reply_*` queue (RPC calls time out)                   | CRITICAL |
| `STOPPED`       | its `reply_*` queue is not in state `running`                              | WARNING  |
| `HOST-QUEUE`    | `<topic>.compute-N.*` has no consumer, host is alive, topic read elsewhere | CRITICAL if it holds messages, else WARNING |
| `NO-FANOUT`     | topic `compute`, `neutron-vo-*`, `q-agent-notifier-*` read without its `_fanout_<hex>` queue | WARNING |

Old queue versions nobody reads and powered-off hosts are not flagged. A host queue whose
agent process is gone entirely is shown as `NO-PROCESS` (verbose) and only carries the
`HOST-QUEUE` flag.

Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN (docker or rabbitmqctl failure, timeout,
unparsable or empty output).

### Parameters

| Parameter                          | Default    | Meaning                                       |
|------------------------------------|------------|-----------------------------------------------|
| `--topics`                         | `compute,neutron-vo-,q-agent-notifier-` | topic prefixes that need a fanout queue |
| `--host-regex`                     | `\.compute-[0-9]+\.` | per-host part of a queue name; also yields the host name |
| `--ignore-hosts compute-163,...`   | none       | hosts under repair                            |
| `--queues reply,host,fanout`       | all        | queue kinds to check; one per Service splits alarms |
| `--max-hosts`                      | `10`       | hosts per category before `+N more`           |
| `--container`                      | `rabbitmq` | RabbitMQ container name                       |
| `--vhost`                          | `/`        | `-p` for list_queues/list_consumers only      |
| `--timeout`                        | `20`       | seconds per rabbitmqctl call                  |
| `--verbose`                        | off        | table, one row per problem                    |
| `--all`                            | off        | table incl. healthy processes (`OK`)          |

Output: `CRITICAL - NO-REPLY: compute-187/ovs; HOST-QUEUE: compute-342/nova(2 msgs) | no_reply=1 ...`
With `--verbose` (PROC: `nova` = nova-compute, `ovs` = neutron-openvswitch-agent); lists in DETAIL go
one item per line):

```text
+---+-------------+------+----------------+------------+----------------------------------------+
| # |     HOST    | PROC |       IP       |  PROBLEM   |                 DETAIL                 |
+---+-------------+------+----------------+------------+----------------------------------------+
| 1 | compute-214 | nova | 198.51.100.73  |  STOPPED   | reply_5e1c9a07d3b24f68a0e7c2d91b4f6a38 |
+---+-------------+------+----------------+------------+----------------------------------------+
| 2 | compute-187 | ovs  | 198.51.100.158 |  NO-REPLY  |                                        |
+---+-------------+------+----------------+------------+----------------------------------------+
| 3 | compute-342 | nova | 198.51.100.26  | HOST-QUEUE |            compute (2 msgs)            |
+---+-------------+------+----------------+------------+----------------------------------------+
| 4 | compute-129 | ovs  | 198.51.100.241 | NO-FANOUT  |          neutron-vo-Port-1.10          |
|   |             |      |                |            |      q-agent-notifier-dvr-update       |
|   |             |      |                |            |     q-agent-notifier-tunnel-update     |
+---+-------------+------+----------------+------------+----------------------------------------+
```

Perfdata: `no_reply`, `stopped_reply`, `host_queue_unconsumed`, `host_queue_msgs`, `no_fanout`,
`processes`.

A bad `--host-regex` or an empty `--topics` gives UNKNOWN.
