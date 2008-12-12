#!/usr/bin/perl
#
# hetzner-rdns.pl
# By Stefan Tomanek <stefan@pico.ruhr.de>
# http://stefans.datenbruch.de/rootserver/

use WWW::Mechanize;
use Getopt::Long;


my $prot = "https";
my $host = "www.hetzner.de";
my $entry = "$prot://$host/robot/";

my $user = undef;
my $pass = undef;

my $get = 0;
my $all = 0;
my $del = 0;
my $set = 0;
my $replace = 0;
my $host = undef;
my $ip = undef;
my $batch = 0;


sub show_help {
    print STDERR <<EOF;
hetzner-rdns.pl by Stefan Tomanek <stefan\@pico.ruhr.de>

Authentication:
    --user <login>      Hetzner Robot username
    --password <pass>   Hetzner Robot password
Operation mode:
    --get               Retrieve reverse DNS entries
    --set               Set a new reverse DNS entry
    --delete            Delete an existing DNS entry
    
    --batch             Read list of ip addresses and hostnames from STDIN
                        and transmit all mappings to Hetzner

Parameters:
    --ip <address>      IP address
    --hostname          Hostname to set
    --replace           Replace existing DNS entry
    --all               Retrieve all ip addresses
EOF
    exit 1;
}

sub checkInput {

    unless (defined $user && defined $pass) {
        return 0;
    }
    
    ($batch xor $set xor $del xor $get) || return 0;

    ( $set &&
        (
            not defined $host ||
            not defined $ip ||
            not ($host =~ /^[[:alnum:].]+$/) || 
            not ($ip =~ /^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/)
        )
    ) && return 0;
    ( $del &&
        (
            not defined $ip || 
            not ($ip =~ /[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/)
        )
    ) && return 0;

    ( $batch && (defined $host || defined $ip) ) && return 0;
    return 1;
}

GetOptions (
    'username|user|u=s' => \$user,
    'password|pass|p=s' => \$pass,
    'get|g' => \$get,
    'set|s' => \$set,
    'replace|r!' => \$replace,
    'delete|del|d' => \$del,
    'host|hostname|name|h|n=s' => \$host,
    'ip|i=s' => \$ip,
    'batch|b' => \$batch,
    'all!' => \$all
) || show_help();

checkInput || show_help();

sub login {
    my $mech = WWW::Mechanize->new( autocheck => 1 );
    $mech->get( $entry );

    $mech->submit_form(
        form_number => 1,
        fields => {
            login => $user,
            passwd => $pass
        }
    );
    
    if ($mech->content() =~ /Bitte überprüfen Sie Ihre Logindaten!/) {
        # login failed
        return undef;
    }
    return $mech;
}

sub get_hosts {
    my ($mech) = @_;
    my %hosts = ();
    $mech->follow_link( url => 'rdns_2.php' );
    my $page = $mech->content();
    while ( $page =~ /<option value="(\d+)">(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})&nbsp;&nbsp;->&nbsp;&nbsp;([[:alnum:].\-]+)/g  ) {
        my $i = $2;
        my $h = $3;
        $hosts{$i} = $h;
    }
    if ($all) {
        $mech->follow_link( url => 'rdns_1.php' );
        my $page = $mech->content();
        while ( $page =~ /<option value="(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})">/g ) {
            $hosts{$1} = "";
        }
    }
    return \%hosts;
}

sub set_host {
    my ($mech, $ip, $host) = @_;
    my $hosts = get_hosts($mech);
    if (defined $hosts->{$ip}) {
        if ($hosts->{$ip} eq $host) {
            print STDERR "No change to address $ip necessary, already mapped to $host\n";
            return;
        }
        if ($replace) {
            print STDERR "Address $ip already assigned, replacing existing reverse entry\n";
            delete_host( $mech, $ip );
        } else {
            print STDERR "Address $ip already assigned, not replacing it!\n";
        }
    }

    $mech->follow_link( url => 'rdns_1.php' );
    $mech->submit_form(
        form_number => 1,
        fields => {
            ip => $ip,
            name => $host
        }
    );
}

sub delete_host {
    my ($mech, $ip) = @_;
    $mech->follow_link( url => 'rdns_2.php' );
    my $page = $mech->content();
    while ( $page =~ /<option value="(\d+)">(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})&/g ) {
        my ($rdns_id, $address) = ($1, $2);
        next unless $address eq $ip;

        $mech->submit_form(
            form_number => 1,
            fields => {
                rdns => $rdns_id
            }
        );
        print STDERR "Removed reverse entry for address $ip\n";
        return;
    }
    print STDERR "Unable to remove reverse entry $ip, probably none set\n";
}

sub ip_to_n {
    my ($ip) = @_;
    my $i = 1;
    my $n = 0;
    for my $q (reverse split /\./, $ip) {
        $n += (256**$i)*$q;
        $i++;
    }
    return $n;
}

sub ip_sort {
    ip_to_n($a) <=> ip_to_n($b);
}

sub batch_process {
    my ($m) = @_;
    # read STDIN
    while (<STDIN>) {
        my ($i, $h) = split /\s+/;
        if (defined $h && not $h eq "") {
            # set entry
            set_host($m, $i, $h);
        } else {
            # delete entry
            delete_host($m, $i);
        }
    }
}

my $m = login();
unless (defined $m) {
    print STDERR "Invalid login data\n";
    #exit 1;
}

if ($set) {
    set_host( $m, $ip, $host );
} elsif ($del) {
    delete_host( $m, $ip );
} elsif ($get) {
    my %hosts = %{ get_hosts( $m ) };

    for my $i (sort ip_sort keys %hosts) {
        my $h = $hosts{$i};
        next if (defined $host && $host ne $h);
        next if (defined $ip && $ip ne $i);
        print STDOUT "$i\t$h\n";
    }
} elsif ($batch) {
    batch_process($m);
}
