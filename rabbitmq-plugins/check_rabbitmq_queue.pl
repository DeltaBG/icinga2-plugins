#!/usr/bin/env perl
#
# check_rabbitmq_overview
#
# Use the management APIs to check a queue
#
use strict;
use warnings;

use Monitoring::Plugin qw(OK CRITICAL WARNING UNKNOWN);
use Monitoring::Plugin::Functions qw(%STATUS_TEXT);
use LWP::UserAgent;
use URI::Escape;
use JSON;

use vars qw($VERSION $PROGNAME  $verbose $timeout);
$VERSION = '2.0.3';

# get the base name of this script for use in the examples
use File::Basename;
$PROGNAME = basename($0);

my $p = Monitoring::Plugin->new(
    usage => "Usage: %s [options] -H hostname --queue queue",
    license => "",
    version => $VERSION,
    blurb => 'This plugin uses the RabbitMQ management API to monitor a specific queue.',
);

$p->add_arg(spec => 'hostname|host|H=s',
    help => "Specify the host to connect to",
    required => 1
);
$p->add_arg(spec => 'port=i',
    help => "Specify the port to connect to (default: %s)",
    default => 15672
);

$p->add_arg(spec => 'username|user|u=s',
    help => "Username (default: %s)",
    default => "guest",
);
$p->add_arg(spec => 'password|p=s',
    help => "Password (default: %s)",
    default => "guest"
);

$p->add_arg(spec => 'vhost=s',
    help => "Specify the vhost where the queue resides (default: %s)",
    default => "/"
);
$p->add_arg(spec => 'queue=s',
    help => "Specify the queue to check (default: %s)",
    default => "all"
);

$p->add_arg(spec => 'filter=s',
    help => "Specify the queues to filter for the check. It's a perl regex (default: %s)",
    default => ".*"
);


$p->add_arg(
    spec => 'warning|w=s',
    help =>
qq{-w, --warning=THRESHOLD[,THRESHOLD[,THRESHOLD[,THRESHOLD]]]
   Warning thresholds specified in following order:
   messages[,messages_ready[,messages_unacknowledged[,consumers]]]
   Specify -1 if no warning threshold.},

);

$p->add_arg(
    spec => 'critical|c=s',
    help =>
qq{-c, --critical=THRESHOLD[,THRESHOLD[,THRESHOLD[,THRESHOLD]]]
   Critical thresholds specified in following order:
   messages[,messages_ready[,messages_unacknowledged[,consumers]]]
   Specify -1 if no critical threshold.},
);

$p->add_arg(spec => 'ssl|ssl!',
    help => "Use SSL (default: false)",
    default => 0
);

$p->add_arg(spec => 'ssl_strict|ssl_strict!',
    help => "Verify SSL certificate (default: true)",
    default => 1
);

$p->add_arg(spec => 'proxy|proxy!',
    help => "Use environment proxy (default: true)",
    default => 1
);
$p->add_arg(spec => 'proxyurl=s',
    help => "Use proxy url like http://proxy.domain.com:8080",
);

$p->add_arg(spec => 'ignore|ignore!',
    help => "Ignore alerts if queue does not exist (default: false)",
    default => 0
);

# Parse arguments and process standard ones (e.g. usage, help, version)
$p->getopts;


# perform sanity checking on command line options
my %warning;
if (defined $p->opts->warning) {
    my @warning = split(',', $p->opts->warning);
    $p->nagios_die("You should specify 1 to 4 ranges for --warning argument") unless $#warning < 4;

    $warning{'messages'} = shift @warning;
    $warning{'messages_ready'} = shift @warning;
    $warning{'messages_unacknowledged'} = shift @warning;
    $warning{'consumers'} = shift @warning;
}

my %critical;
if (defined $p->opts->critical) {
    my @critical = split(',', $p->opts->critical);
    $p->nagios_die("You should specify specify 1 to 4 ranges for --critical argument") unless $#critical < 4;

    $critical{'messages'} = shift @critical;
    $critical{'messages_ready'} = shift @critical;
    $critical{'messages_unacknowledged'} = shift @critical;
    $critical{'consumers'} = shift @critical;
}


##############################################################################
# check stuff.

my $hostname=$p->opts->hostname;
my $port=$p->opts->port;
my $vhost=uri_escape($p->opts->vhost);
my $queue=$p->opts->queue;
my $filter=$p->opts->filter;
my $ignore=$p->opts->ignore;

my $ua = LWP::UserAgent->new;
if (defined $p->opts->proxyurl)
{
    $ua->proxy('http', $p->opts->proxyurl);
}
elsif($p->opts->proxy == 1 )
{
    $ua->env_proxy;
}
$ua->agent($PROGNAME.' ');
$ua->timeout($p->opts->timeout);
if ($p->opts->ssl and $ua->can('ssl_opts')) {
    $ua->ssl_opts(verify_hostname => $p->opts->ssl_strict);
}

my $url = "";
if ($queue eq "all"){
    $url = sprintf("http%s://%s:%d/api/queues/%s", ($p->opts->ssl ? "s" : ""), $hostname, $port, $vhost);
} else{
    $url = sprintf("http%s://%s:%d/api/queues/%s/%s", ($p->opts->ssl ? "s" : ""), $hostname, $port, $vhost, $queue);
}
my ($retcode, $result) = request($url);
if ($retcode == 404 && $ignore) {
    $p->nagios_exit(OK, "$result : $url");
}
if ($retcode != 200) {
    $p->nagios_exit(CRITICAL, "$result : $url");
}

my @values = ();
my @metrics = ("messages", "messages_ready", "messages_unacknowledged", "consumers");

for my $metric (@metrics) {
    my $warning = undef;
    $warning = $warning{$metric} if (defined $warning{$metric} and $warning{$metric} ne -1);
    my $critical = undef;
    $critical = $critical{$metric} if (defined $critical{$metric} and $critical{$metric} ne -1);
    if(ref($result) eq 'ARRAY'){
        my $message = "";
        my $nb_matched_queues = 0;
        my $sum_metric_value = 0;
        for my $queue (@$result){
            next if $queue->{name} !~ /$filter/i;
            my $value = 0;
            $value = $queue->{$metric} if defined $queue->{$metric};
            my $code = $p->check_threshold(check => $value, warning => $warning, critical=> $critical);
            push @values, $code;

            $nb_matched_queues++;
            $sum_metric_value += $value;

            $p->add_message($code, sprintf("$queue->{name} : $metric ".$STATUS_TEXT{$code}." (%d)", $value)) unless $code == 0;
        }
        $p->add_perfdata(label=>$metric, value=>sprintf("%.4f", $sum_metric_value/$nb_matched_queues), warning=>$warning, critical=> $critical);
    } else{
        my $value = 0;
        $value = $result->{$metric} if defined $result->{$metric};
        my $code = $p->check_threshold(check => $value, warning => $warning, critical=> $critical);
        push @values, $code;

        $p->add_message($code, sprintf("$metric ".$STATUS_TEXT{$code}." (%d)", $value)) ;
        $p->add_perfdata(label=>$metric, value => $value, warning=>$warning, critical=> $critical);
    }
}
$p->add_message(0, sprintf("All queues under the thresholds")) unless grep {$_ > 0} @values;

my ($code, $message) = $p->check_messages(join_all=>', ');

$code = 1 if grep /1/,@values;
$code = 2 if grep /2/,@values;

$p->nagios_exit(return_code => $code, message => $message);


sub request {
    my ($url) = @_;
    my $req = HTTP::Request->new(GET => $url);
    $req->authorization_basic($p->opts->username, $p->opts->password);
    my $res = $ua->request($req);

    if (!$res->is_success) {
        # Deal with standard error conditions - make the messages more sensible
        if ($res->code == 400) {
            my $bodyref = decode_json $res->content;
            return (400, $bodyref->{'reason'});

        }
        $res->code == 404 and return (404, "Not Found");
        $res->code == 401 and return (401, "Access Refused");
        $res->status_line =~ /Can\'t connect/ and return (500, "Connection Refused : $url");
        if ($res->code < 200 or $res->code > 400 ) {
            return ($res->code, "Received ".$res->status_line);
        }
    }
    my $bodyref = decode_json $res->content;
    return($res->code, $bodyref);
}

=head1 NAME

check_rabbitmq_queue - Nagios plugin using RabbitMQ management API to
count the messages pending and consumers on a given queue

=head1 SYNOPSIS

check_rabbitmq_queue [options] -H hostname --queue queue

=head1 DESCRIPTION

Use the management interface of RabbitMQ to count the number of pending,
ready and unacknowledged messages and number of consumers.  These are
published as performance metrics for the check.

Critical and warning thresholds can be set for each of the metrics.

It uses Monitoring::Plugin and accepts all standard Nagios options.

=head1 OPTIONS

=over

=item -h | --help

Display help text

=item -v | --verbose

Verbose output

=item -t | --timeout

Set a timeout for the check in seconds

=item -H | --hostname | --host

The host to connect to

=item --port

The port to connect to (default: 15672)

=item --ssl

Use SSL when connecting (default: false)

=item --username | --user

The user to connect as (default: guest)

=item --password | -p

The password for the user (default: guest)

=item -w | --warning

The warning levels for each count of messages, messages_ready,
messages_unacknowledged and consumers.  This field consists of
one to four comma-separated thresholds.  Specify -1 if no threshold
for a particular count.

=item -c | --critical

The critical levels for each count of messages, messages_ready,
messages_unacknowledged and consumers.  This field consists of
one to four comma-separated thresholds.  Specify -1 if no threshold
for a particular count.

=item --ignore

If the queue specified does not exist, this option ignores
CRITICAL alerts and returns a status of OK.  Useful for scenarios
where queue existence is optional.

=back

=head1 THRESHOLD FORMAT

The format of thresholds specified in --warning and --critical arguments
is defined at <http://nagiosplug.sourceforge.net/developer-guidelines.html#THRESHOLDFORMAT>.

For example to be crtical if more than 100 messages, more than 90 messages_ready,
more than 20 messages_unacknowledged or no fewer than 10 consumers use

--critical=100,90,20,10:

=head1 EXAMPLES

The defaults all work with a standard fresh install of RabbitMQ, and all that
is needed is to specify the host to connect to:

    check_rabbitmq_queue -H rabbit.example.com

This returns a standard Nagios result:

    RABBITMQ_OVERVIEW OK - messages OK (25794) messages_ready OK (22971)
      messages_unacknowledged OK (2823) consumers OK (10) | messages=25794;;
      messages_ready=22971;; messages_unacknowledged=2823;; consumers=10;;

=head1 ERRORS

The check tries to provide useful error messages on the status line for
standard error conditions.

Otherwise it returns the HTTP Error message returned by the management
interface.

=head1 EXIT STATUS

Returns zero if check is OK otherwise returns standard Nagios exit codes to
signify WARNING, UNKNOWN or CRITICAL state.

=head1 SEE ALSO

See Monitoring::Plugin(3)

The RabbitMQ management plugin is described at
http://www.rabbitmq.com/management.html

=head1 LICENSE

This file is part of nagios-plugins-rabbitmq.

Copyright 2010, Platform 14.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 AUTHOR

James Casey <jamesc.000@gmail.com>

=cut

1;
