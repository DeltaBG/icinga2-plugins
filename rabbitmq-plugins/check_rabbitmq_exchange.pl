#!/usr/bin/env perl
#
# check_rabbitmq_exchange
#
# Use the management APIs to check an exchange
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
    usage => "Usage: %s [options] -H hostname --exchange exchange --period period",
    license => "",
    version => $VERSION,
    blurb => 'This plugin uses the RabbitMQ management API to monitor a specific exchange.',
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
    help => "Specify the vhost where the exchange resides (default: %s)",
    default => "/"
);
$p->add_arg(spec => 'exchange=s',
    help => "Specify the exchange to check",
    required => 1
);

$p->add_arg(spec => 'period=s',
    help => "Specify the time period for which you want to check the thresholds",
    required => 1
);

$p->add_arg(
    spec => 'warning|w=s',
    help =>
qq{-w, --warning=THRESHOLD[,THRESHOLD[,THRESHOLD]]
   Warning thresholds specified in order that the metrics are returned.
   Specify -1 if no warning threshold.},

);

$p->add_arg(
    spec => 'critical|c=s',
    help =>
qq{-c, --critical=THRESHOLD[,THRESHOLD[,THRESHOLD]]
   Critical thresholds specified in order that the metrics are returned.
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

# Parse arguments and process standard ones (e.g. usage, help, version)
$p->getopts;


# perform sanity checking on command line options
my %warning;
if (defined $p->opts->warning) {
    my @warning = split(',', $p->opts->warning);
    $p->nagios_die("You should specify 1 to 3 ranges for --warning argument") unless $#warning < 3;

    $warning{'confirm'} = shift @warning;
    $warning{'publish_in'} = shift @warning;
    $warning{'publish_out'} = shift @warning;
}

my %critical;
if (defined $p->opts->critical) {
    my @critical = split(',', $p->opts->critical);
    $p->nagios_die("You should specify 1 to 3 ranges for --critical argument") unless $#critical < 3;

    $critical{'confirm'} = shift @critical;
    $critical{'publish_in'} = shift @critical;
    $critical{'publish_out'} = shift @critical;
}


##############################################################################
# check stuff.

my $hostname=$p->opts->hostname;
my $port=$p->opts->port;
my $vhost=uri_escape($p->opts->vhost);
my $exchange=$p->opts->exchange;
my $timePeriod=$p->opts->period;

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
if ($p->opts->ssl) {
    $ua->ssl_opts(verify_hostname => $p->opts->ssl_strict);
}

my $url = sprintf("http%s://%s:%d/api/exchanges/%s/%s?msg_rates_age=%s&msg_rates_incr=%s", ($p->opts->ssl ? "s" : ""), $hostname, $port, $vhost, $exchange, $timePeriod, $timePeriod);
my ($retcode, $result) = request($url);
if ($retcode != 200) {
    $p->nagios_exit(CRITICAL, "$result : $url");
}

my @metrics = ("confirm", "publish_in", "publish_out");
for my $metric (@metrics) {
    my $warning = undef;
    $warning = $warning{$metric} if (defined $warning{$metric} and $warning{$metric} ne -1);
    my $critical = undef;
    $critical = $critical{$metric} if (defined $critical{$metric} and $critical{$metric} ne -1);

    my $value = 0;
    $value = $result->{"message_stats"}->{$metric."_details"}->{"avg_rate"} if defined $result->{"message_stats"}->{$metric . "_details"}->{"avg_rate"};
    my $code = $p->check_threshold(check => $value, warning => $warning, critical=> $critical);
    $p->add_message($code, sprintf("$metric"."_avg_rate ".$STATUS_TEXT{$code}." (%f)", $value)) ;
    $p->add_perfdata(label=>$metric."_avg_rate", value => $value, warning=>$warning, critical=> $critical);
}

my ($code, $message) = $p->check_messages(join_all=>', ');
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

check_rabbitmq_exchange - Nagios plugin using RabbitMQ management API to
check the average rate of messages per second during a given period of time on a given exchange

=head1 SYNOPSIS

check_rabbitmq_overview [options] -H hostname --queue exchange --period period

=head1 DESCRIPTION

Use the management interface of RabbitMQ to get the average rate of confirmed,
published in and published out messages per second in a given period of time.  These are
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

=item -p | --password

The password for the user (default: guest)

=item -w | --warning

The warning levels for each average rate of confirmed, published_in and
published_out messages per second for the given period of time.  This field consists of
one to three comma-separated thresholds.  Specify -1 if no threshold
for a particular average rate.

=item -c | --critical

The critical levels for each average rate of confirmed, published_in and
published_out messages per second for the given period of time.  This field consists of
one to four comma-separated thresholds.  Specify -1 if no threshold
for a particular average rate.

=back

=head1 THRESHOLD FORMAT

The format of thresholds specified in --warning and --critical arguments
is defined at <http://nagiosplug.sourceforge.net/developer-guidelines.html#THRESHOLDFORMAT>.

For example, to be crtical if average rates are less than 2 messages confirmed per second, less than 2 published_in messages per second,
or less than 4 published_out messages per second use

--critical=2:,2:,4:

=head1 EXAMPLES

The defaults all work with a standard fresh install of RabbitMQ, and all that
is needed is to specify the host to connect to:

    check_rabbitmq_exchange -H rabbit.example.com

This returns a standard Nagios result:

    RABBITMQ_OVERVIEW OK - confirm_avg_rate OK (2.5) publish_in_avg_rate OK (2.5)
      publish_out_avg_rate OK (5) | confirm_avg_rate=2.5;;
      publish_in_avg_rate=2.5;; publish_out_avg_rate=5;;

=head1 ERRORS

The check tries to provide useful error messages on the status line for
standard error conditions.

Otherwise it returns the HTTP Error message returned by the management
interface.

=head1 EXIT STATUS

Returns zero if check is OK otherwise returns standard Nagios exit codes to
signify WARNING, UNKNOWN or CRITICAL state.

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

Maria Fernandez

=cut

1;
