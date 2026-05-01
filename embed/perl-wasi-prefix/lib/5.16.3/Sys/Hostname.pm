package Sys::Hostname;

use strict;

use Carp;

require Exporter;

our @ISA    = qw/ Exporter /;
our @EXPORT = qw/ hostname /;

our $VERSION;

our $host;

BEGIN {
    $VERSION = '1.16';
    {
        local $SIG{__DIE__};
        eval {
            require XSLoader;
            XSLoader::load();
        };
        warn $@ if $@;
    }
}

sub hostname {

    return $host if defined $host;

    $host = ghname() if defined &ghname;
    return $host if defined $host;

    if ( $^O eq 'VMS' ) {

        eval { local $SIG{__DIE__}; $host = ( gethostbyname('me') )[0] };
        if ($@) { return $host = $ENV{'SYS$NODE'}; }

        $host =
             $ENV{'ARPANET_HOST_NAME'}
          || $ENV{'INTERNET_HOST_NAME'}
          || $ENV{'MULTINET_HOST_NAME'}
          || $ENV{'UCX$INET_HOST'}
          || $ENV{'TCPWARE_DOMAINNAME'}
          || $ENV{'NEWS_ADDRESS'};
        return $host if $host;

        my ($rslt) = `hostname`;
        if ( $rslt !~ /IVVERB/ ) { ($host) = $rslt =~ /^(\S+)/; }
        return $host if $host;

        $host = '';
        croak "Cannot get host name of local machine";

    }
    elsif ( $^O eq 'MSWin32' ) {
        ($host) = gethostbyname('localhost');
        chomp( $host = `hostname 2> NUL` ) unless defined $host;
        return $host;
    }
    elsif ( $^O eq 'epoc' ) {
        $host = 'localhost';
        return $host;
    }
    else { 

        local $ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin';

        eval {
            local $SIG{__DIE__};
            require "syscall.ph";
            $host = "\0" x 65;
            syscall( &SYS_gethostname, $host, 65 ) == 0;
        }

          || eval {
            local $SIG{__DIE__};
            require "sys/syscall.ph";
            require "sys/systeminfo.ph";
            $host = "\0" x 65;
            syscall( &SYS_systeminfo, &SI_HOSTNAME, $host, 65 ) != -1;
          }

          || eval {
            local $SIG{__DIE__};
            local $SIG{CHLD};
            $host = `(hostname) 2>/dev/null`;
          }

          || eval {
            local $SIG{__DIE__};
            require POSIX;
            $host = ( POSIX::uname() )[1];
          }

          || eval {
            local $SIG{__DIE__};
            $host = `uname -n 2>/dev/null`;
          }

          || croak "Cannot get host name of local machine";

        $host =~ tr/\0\r\n//d;
        $host;
    }
}

1;

__END__


