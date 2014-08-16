#!/usr/bin/env perl

use strict;
use warnings;

use Data::Dumper qw/Dumper/;
use POSIX qw/strftime/;
use Time::HiRes qw//;
use Net::Graphite;
use Sys::Hostname qw//;
use Getopt::Long;
use DBI;

# use 5.20.0;

GetOptions(
    'graphite_hostname=s' => \(my $graphite_host),
    'local_hostname=s'    => \(my $local_hostname = Sys::Hostname::hostname),
    'dry_run'             => \(my $dry_run),
);

unless ($graphite_host) {
    die "usage: $0 --graphite_host=graphite.foo.com";
}

my $dbh = DBI->connect("DBI:SQLite:$ENV{HOME}/.macmon.db");

log_message('> retrieving netstat');
my @netstat_lines = qx{ /usr/sbin/netstat -b -i };

log_message('> retrieving ioreg');
my @ioreg_lines = grep {/CycleCount|Capacity|IsCharging|ExternalConnected/} 
                  qx{ /usr/sbin/ioreg -l };

log_message('> retrieving tempmonitor');
my @temperature_lines = -d "/Applications/TemperatureMonitor.app" ? qx{ /Applications/TemperatureMonitor.app/Contents/MacOS/tempmonitor -a -l } : ();

log_message('> retrieving df');
my @df_lines = qx{ /bin/df -k -l };

log_message('> retrieving uptime');
my @uptime_lines = qx{ /usr/bin/uptime };

log_message('> retrieving vm_stat');
my @vmstat_lines = qx{ /usr/bin/vm_stat -c1 1 };

log_message('> retrieving iostat');
my @iostat_lines = qx{ /usr/sbin/iostat -C -n0 };

################################################################################
################################################################################

my %interfaces = ( en0 => {}, en1 => {}, en4 => {} );
foreach my $netstat_line (@netstat_lines) {
    my @netstat = split /\s+/, $netstat_line;

    my @netstat_keys = qw/
      interface mtu network address packets_in errors_in bytes_in packets_out errors_out bytes_out coll
    /;
    my %netstat_line;
    @netstat_line{@netstat_keys} = @netstat;

    my $interface_data = $interfaces{ $netstat_line{interface} } or next;
    keys %$interface_data and next;

    $interface_data->{bytes_in} = $netstat_line{bytes_in};
    $interface_data->{bytes_out} = $netstat_line{bytes_out};
}

################################################################################
################################################################################

my %ioreg_info;
foreach my $ioreg_line (@ioreg_lines) {
    my ($key, $value) = ($ioreg_line =~ m/\A [\s|]+ "(\w+)" [ ] = [ ] ["]?(\w+)["]? /xms);
    next unless $key && defined $value;
    $ioreg_info{$key} = $value;

    if ( defined $ioreg_info{MaxCapacity} and defined $ioreg_info{CurrentCapacity} and defined $ioreg_info{DesignCapacity} ) {
        $ioreg_info{PercentCapacity} = $ioreg_info{CurrentCapacity} / $ioreg_info{MaxCapacity};
        $ioreg_info{DesignPercent} = $ioreg_info{CurrentCapacity} / $ioreg_info{DesignCapacity};
    }
}

################################################################################
################################################################################

my %temperature_info;
foreach my $temperature_line (@temperature_lines) {

    chomp $temperature_line;

    my ($device, $temperature) = split /: /, $temperature_line;
    next unless $device && $temperature; 
    $temperature =~ s/ C//;
    $temperature_info{$device} = $temperature;
}

################################################################################
################################################################################

my %df_info;
foreach my $df_line (@df_lines) {
    my @df_keys = qw/
        device blocks used available capacity iused ifree iusedpct mount
    /;
    my %df_line;
    @df_line{@df_keys} = split /\s+/, $df_line;
    s/\A(\d+)\z/$1 * 1024/e foreach values %df_line;
    next unless $df_line{device} =~ m|/dev/disk[01]s?|;
    $df_line{device} =~ s|/dev/||;
    $df_info{ $df_line{device} } = \%df_line;
}

################################################################################
################################################################################

# my %uptime_info;
# @uptime_info{qw/ 1m 5m 15m /} = (split /\s+/, $uptime_lines[0])[-3, -2, -1];

################################################################################
################################################################################

my %vmstat_info;
foreach my $vmstat_line (@vmstat_lines) {
    $vmstat_line =~ s/\A\s+//;
    next unless $vmstat_line =~ m/\A\d/;
    my @vmstat_keys = qw/
        free active specul inactive throttle wired prgable faults copy 0fill reactive purged file-backed anonymous cmprssed cmprssor dcomprs comprs pageins pageout swapins swapouts
    /;

    @vmstat_info{@vmstat_keys} = split /\s+/ => $vmstat_line;

    s{\A(\d+)\z}{$1 * 4096}e foreach @vmstat_info{qw/
        free active specul inactive throttle wired prgable 
    /};
}

################################################################################
################################################################################

my %iostat_info;
foreach my $iostat_line (@iostat_lines) {
    $iostat_line =~ s/\A\s+//;
    next unless $iostat_line =~ m/\A\d/;

    my @iostat_keys = qw/
        user system idle 1m 5m 15m
    /;

    @iostat_info{@iostat_keys} = split /\s+/ => $iostat_line;
}

################################################################################
################################################################################

my %raw_data = (
    local_hostname   => $local_hostname,
    graphite_host    => $graphite_host,
    interfaces       => \%interfaces,
    ioreg_info       => \%ioreg_info,
    df_info          => \%df_info,
    temperature_info => \%temperature_info,
    # uptime_info      => \%uptime_info,
    vmstat_info      => \%vmstat_info,
    iostat_info      => \%iostat_info,
);

$dry_run and warn Dumper(\%raw_data);

my ( %send_to_graphite, $graphite_text );

$graphite_text = pack_graphite(\%raw_data, \%send_to_graphite);

if ( $dry_run ) {
    # warn Dumper({ graphite_text => $graphite_text });
    die 'dry_run=1; not sending';
}
else {
    my $graphite = Net::Graphite->new(
        host  => $graphite_host,
        # trace => 1,
    );
    $graphite->send(data => $graphite_text);
}

################################################################################
################################################################################

sub log_message {
    my $milliseconds = (split /[.]/ => Time::HiRes::time)[1];
    my $now = strftime '%F %T', localtime;
    my $message = sprintf "[%s.%05d] [%5s] %s\n", $now, $milliseconds, $$, $_[0];
    # print STDERR $message;
}

sub pack_graphite {
    my ($raw_data, $send_to_graphite) = @_;

    my $local_hostname = $raw_data->{local_hostname};

    my $get_network_diff_via_dbh = sub {
        my ($interface_key, $byte_value) = @_;

        # warn "$interface_key, $byte_value";

        my $bytes_diff = 0;

        if ( $byte_value ) {
            my $previous_byte_value = $dbh->selectrow_array("SELECT macmon_value FROM macmon WHERE macmon_key = ?", {}, $interface_key);
            $bytes_diff = $byte_value - $previous_byte_value;
            $dbh->do("UPDATE macmon SET macmon_value = ? where macmon_key = ?", {}, $byte_value, $interface_key);
        }

        $interface_key =~ s/interfaces/network/;
        $interface_key =~ s/bytes_out/tx_bytes/;
        $interface_key =~ s/bytes_in/rx_bytes/;

        return ( $interface_key, $bytes_diff );
    };

    my $mangle_ioreg_battery_info = sub {
        my ($k, $v) = @_;
        $k =~ s/ioreg_info/battery/;
        $v = lc($v) eq 'yes' ? 1 : 0;
        return $k, $v;
    };

    my %transform = (
        'vmstat_info.free'              => 'memory.MemFree',
        'vmstat_info.active'            => 'memory.Active',
        'vmstat_info.inactive'          => 'memory.Inactive',
        'iostat_info.1m'                => 'loadavg.01',
        'iostat_info.5m'                => 'loadavg.05',
        'iostat_info.15m'               => 'loadavg.15',
        'iostat_info.user'              => 'cpu.total.user',
        'iostat_info.system'            => 'cpu.total.system',
        'iostat_info.idle'              => 'cpu.total.idle',
        'ioreg_info.DesignCapacity'     => 'battery.DesignCapacity',
        'ioreg_info.MaxCapacity'        => 'battery.MaxCapacity',
        'ioreg_info.CurrentCapacity'    => 'battery.CurrentCapacity',
        'ioreg_info.PercentCapacity'    => 'battery.PercentCapacity',
        'ioreg_info.DesignPercent'      => 'battery.DesignPercent',
        'ioreg_info.CycleCount'         => 'battery.CycleCount',
        'ioreg_info.IsCharging'         => $mangle_ioreg_battery_info,
        'ioreg_info.ExternalConnected'  => $mangle_ioreg_battery_info,
        'df_info.disk1.used'            => 'diskspace.root.byte_used',
        'df_info.disk1.available'       => 'diskspace.root.byte_free',
        'interfaces.en0.bytes_in'       => $get_network_diff_via_dbh,
        'interfaces.en0.bytes_out'      => $get_network_diff_via_dbh,
        'interfaces.en1.bytes_in'       => $get_network_diff_via_dbh,
        'interfaces.en1.bytes_out'      => $get_network_diff_via_dbh,
        'interfaces.en4.bytes_in'       => $get_network_diff_via_dbh,
        'interfaces.en4.bytes_out'      => $get_network_diff_via_dbh,
    );

    SOURCE:
    while (my ($source_key, $destination_key) = each %transform) {
        my ($level1, $level2, $level3) = split /[.]/ => $source_key;

        my $value;

        if ( $level1 and $level2 and !$level3 ) {
            $value = $raw_data{$level1}{$level2};
        }
        elsif ( $level1 and $level2 and $level3 ) {
            $value = $raw_data{$level1}{$level2}{$level3};
        }

        if ( ref($destination_key) eq 'CODE' ) {
            # warn "executing $source_key CODEREF";
            ($destination_key, $value) = $destination_key->($source_key, $value);
            next SOURCE unless ( $destination_key and defined $value );
        }

        my $qualified_destination = sprintf 'servers.%s.%s', $local_hostname, $destination_key;

        $dry_run and warn "$source_key( value: $value ) => servers.$local_hostname.$destination_key";

        $send_to_graphite->{$qualified_destination} = $value;
    }

    my $now = time;
    return join "\n" => map { sprintf "%s %s %s", $_, $send_to_graphite->{$_}, $now } keys %$send_to_graphite;
}

__DATA__

# netstat -b -i
Name  Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
lo0   16384 <Link#1>                         28338     0    4130031    28338     0    4130031     0
lo0   16384 localhost   ::1                  28338     -    4130031    28338     -    4130031     -
lo0   16384 127           localhost          28338     -    4130031    28338     -    4130031     -
lo0   16384 localhost   fe80:1::1            28338     -    4130031    28338     -    4130031     -
gif0* 1280  <Link#2>                             0     0          0        0     0          0     0
stf0* 1280  <Link#3>                             0     0          0        0     0          0     0
en0   1500  <Link#4>    10:9a:dd:58:c0:6f  7968840     0 4795960389 30171941     0 43120998925     0
en0   1500  quark.local fe80:4::129a:ddff  7968840     - 4795960389 30171941     - 43120998925     -
en0   1500  10.10.10/24   10.10.10.7       7968840     - 4795960389 30171941     - 43120998925     -
en1   1500  <Link#5>    f0:b4:79:22:c6:f5   205460     0  100192067    26751     0    4069894     0
en1   1500  quark.local fe80:5::f2b4:79ff   205460     -  100192067    26751     -    4069894     -
en1   1500  10.10.10/24   10.10.10.7        205460     -  100192067    26751     -    4069894     -
fw0   4078  <Link#6>    70:cd:60:ff:fe:14:29:80        0     0          0        0     0        692     0
p2p0  2304  <Link#7>    02:b4:79:22:c6:f5        0     0          0        0     0          0     0


# ioreg -l | egrep '(CycleCount|Capacity)'
    | |           "MaxCapacity" = 3555
    | |           "CurrentCapacity" = 3555
    | |           "LegacyBatteryInfo" = {"Amperage"=0,"Flags"=5,"Capacity"=3555,"Current"=3555,"Voltage"=12234,"Cycle Count"=340}
    | |           "CycleCount" = 340
    | |           "DesignCapacity" = 5770
    | |           "DesignCycleCount9C" = 1000


# /Applications/TemperatureMonitor.app/Contents/MacOS/tempmonitor -a -l
SMART Disk Hitachi HTS545025B9SA02 (101116PBL200NSH4HT8V): 35 C
SMART Disk OCZ-AGILITY3 (OCZ-W31X44OHP034GA82): 30 C
SMB NORTHBRIDGE CHIP DIE: 53 C
SMB NORTHBRIDGE CHIP DIE: 59 C
SMC BATTERY: 36 C
SMC BATTERY POSITION 2: 36 C
SMC BATTERY POSITION 3: 36 C
SMC CPU A DIODE: 55 C
SMC CPU A PROXIMITY: 51 C
SMC LEFT PALM REST: 34 C
SMC MAIN HEAT SINK 2: 49 C
SMC NORTHBRIDGE POS 1: 45 C

# df -k -l
Filesystem   1024-blocks      Used Available Capacity  iused    ifree %iused  Mounted on
/dev/disk0s2   116381216  95680984  20444232    83% 23984244  5111058   82%   /
/dev/disk1s2   232924400 150628740  82295660    65% 37657183 20573915   65%   /Volumes/archive
/dev/disk3s2       10200      7628      2572    75%     1905      643   75%   /Volumes/Temperature Monitor 4.98

# uptime
21:10  up 2 days, 20:55, 10 users, load averages: 1.49 1.51 1.68

# vm_stat -c1 1
Mach Virtual Memory Statistics: (page size of 4096 bytes)
    free   active   specul inactive throttle    wired  prgable   faults     copy    0fill reactive   purged file-backed anonymous cmprssed cmprssor  dcomprs   comprs  pageins  pageout  swapins swapouts
  262768   613583    12959   332735        0   183792     1364  146832K  8432703 65102201   247457    70287      412326    546951   189105   101051    80334   308327  2869482   220762    16756    18050 
