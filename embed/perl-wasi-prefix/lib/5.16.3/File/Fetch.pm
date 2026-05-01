package File::Fetch;

use strict;
use FileHandle;
use File::Temp;
use File::Copy;
use File::Spec;
use File::Spec::Unix;
use File::Basename qw[dirname];

use Cwd qw[cwd];
use Carp qw[carp];
use IPC::Cmd qw[can_run run QUOTE];
use File::Path qw[mkpath];
use File::Temp qw[tempdir];
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load];
use Locale::Maketext::Simple Style => 'gettext';

use vars qw[ $VERBOSE $PREFER_BIN $FROM_EMAIL $USER_AGENT
  $BLACKLIST $METHOD_FAIL $VERSION $METHODS
  $FTP_PASSIVE $TIMEOUT $DEBUG $WARN
];

$VERSION     = '0.32';
$VERSION     = eval $VERSION;
$PREFER_BIN  = 0;
$FROM_EMAIL  = 'File-Fetch@example.com';
$USER_AGENT  = "File::Fetch/$VERSION";
$BLACKLIST   = [qw|ftp|];
$METHOD_FAIL = {};
$FTP_PASSIVE = 1;
$TIMEOUT     = 0;
$DEBUG       = 0;
$WARN        = 1;

$METHODS = {
    http  => [qw|lwp httptiny wget curl lftp fetch httplite lynx iosock|],
    ftp   => [qw|lwp netftp wget curl lftp fetch ncftp ftp|],
    file  => [qw|lwp lftp file|],
    rsync => [qw|rsync|]
};

local $Params::Check::VERBOSE             = 1;
local $Params::Check::VERBOSE             = 1;
local $Module::Load::Conditional::VERBOSE = 0;
local $Module::Load::Conditional::VERBOSE = 0;

use constant ON_WIN => ( $^O eq 'MSWin32' );
use constant ON_VMS => ( $^O eq 'VMS' );
use constant ON_UNIX   => ( !ON_WIN );
use constant HAS_VOL   => (ON_WIN);
use constant HAS_SHARE => (ON_WIN);
use constant HAS_FETCH => ( $^O =~ m!^(freebsd|netbsd|dragonfly)$! );


{
    my $Tmpl = {
        scheme => { default  => 'http' },
        host   => { default  => 'localhost' },
        path   => { default  => '/' },
        file   => { required => 1 },
        uri    => { required => 1 },
        vol    => { default  => '' }, share => { default => '' }, _error_msg =>
          { no_override => 1 },
        _error_msg_long => { no_override => 1 },
    };

    for my $method ( keys %$Tmpl ) {
        no strict 'refs';
        *$method = sub {
            my $self = shift;
            $self->{$method} = $_[0] if @_;
            return $self->{$method};
          }
    }

    sub _create {
        my $class = shift;
        my %hash  = @_;

        my $args = check( $Tmpl, \%hash ) or return;

        bless $args, $class;

        if ( lc( $args->scheme ) ne 'file' and not $args->host ) {
            return $class->_error(
                loc(
                    "Hostname required when fetching from '%1'",
                    $args->scheme
                )
            );
        }

        for (qw[path file]) {
            unless ( $args->$_() )
            { return $class->_error( loc( "No '%1' specified", $_ ) );
            }
        }

        return $args;
    }
}


sub output_file {
    my $self = shift;
    my $file = $self->file;

    $file =~ s/\?.*$//g;

    return $file;
}


sub new {
    my $class = shift;
    my %hash  = @_;

    my ($uri);
    my $tmpl = { uri => { required => 1, store => \$uri }, };

    check( $tmpl, \%hash ) or return;

    my $href = $class->_parse_uri($uri) or return;

    my $ff = $class->_create(%$href) or return;

    return $ff;
}

sub _parse_uri {
    my $self = shift;
    my $uri = shift or return;

    my $href = { uri => $uri };

    $uri =~ s|^(\w+)://||;
    $href->{scheme} = $1;

    if ( $href->{scheme} eq 'file' ) {

        my @parts = split '/', $uri;

        $href->{host} = $parts[0] || '';

        my $index = 1;

        if ( HAS_SHARE and not length $parts[0] and not length $parts[1] ) {

            $href->{host}  = $parts[2] || '';
            $href->{share} = $parts[3] || '';

            $index = 4

        }
        elsif (HAS_VOL) {

            $href->{vol} = $parts[1] || '';

            $href->{vol} =~ s/\A([A-Z])\|\z/$1:/i if ON_WIN;

            $index = 2;
        }

        $href->{path} = join '/', '', splice( @parts, $index, $#parts );

    }
    else {
        @{$href}{qw(host path)} = $uri =~ m|([^/]*)(/.*)$|s;
    }

    {
        my @parts = File::Spec::Unix->splitpath( delete $href->{path} );
        $href->{path} = $parts[1];
        $href->{file} = $parts[2];
    }

    $href->{host} = ''
      if ( $href->{host} eq 'localhost' )
      and ( $href->{scheme} eq 'file' );

    return $href;
}


sub fetch {
    my $self = shift or return;
    my %hash = @_;

    my $target;
    my $tmpl = { to => { default => cwd(), store => \$target }, };

    check( $tmpl, \%hash ) or return;

    my ( $to, $fh );
    if ( ref $target and UNIVERSAL::isa( $target, 'SCALAR' ) ) {
        $to = tempdir( 'FileFetch.XXXXXX', CLEANUP => 1 );

    }
    else {
        $to = $target;

        $to = VMS::Filespec::vmspath($to) if ON_VMS;

        unless ( -d $to ) {
            eval { mkpath($to) };

            return $self->_error( loc( "Could not create path '%1'", $to ) )
              if $@;
        }
    }

    local $ENV{FTP_PASSIVE} = $FTP_PASSIVE;

    my $out_to =
      ON_WIN
      ? $to . '/' . $self->output_file
      : File::Spec->catfile( $to, $self->output_file );

    for my $method ( @{ $METHODS->{ $self->scheme } } ) {
        my $sub = '_' . $method . '_fetch';

        unless ( __PACKAGE__->can($sub) ) {
            $self->_error(
                loc( "Cannot call method for '%1' -- WEIRD!", $method ) );
            next;
        }

        next if grep { lc $_ eq $method } @$BLACKLIST;

        next if $METHOD_FAIL->{$method};

        local $IPC::Cmd::USE_IPC_RUN = 0;

        if ( my $file = $self->$sub( to => $out_to ) ) {

            unless ( -e $file && -s _ ) {
                $self->_error(
                    loc(
                        "'%1' said it fetched '%2', "
                          . "but it was not created",
                        $method,
                        $file
                    )
                );

                $METHOD_FAIL->{$method} = 1;

                next;

            }
            else {

                if ( ref $target and UNIVERSAL::isa( $target, 'SCALAR' ) ) {

                    open my $fh, "<$file" or do {
                        $self->_error(
                            loc( "Could not open '%1': %2", $file, $! ) );
                        return;
                    };

                    $$target = do { local $/; <$fh> };

                }

                my $abs = File::Spec->rel2abs($file);
                return $abs;

            }
        }
    }

    return;
}

sub _lwp_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    my $use_list = {
        LWP              => '0.0',
        'LWP::UserAgent' => '0.0',
        'HTTP::Request'  => '0.0',
        'HTTP::Status'   => '0.0',
        URI              => '0.0',

    };

    if ( can_load( modules => $use_list ) ) {

        my $uri =
          URI->new( File::Spec::Unix->catfile( $self->path, $self->file ) );

        $uri->scheme( $self->scheme );
        $uri->host( $self->scheme eq 'file' ? '' : $self->host );
        $uri->userinfo("anonymous:$FROM_EMAIL") if $self->scheme ne 'file';

        my $ua = LWP::UserAgent->new();
        $ua->timeout($TIMEOUT) if $TIMEOUT;
        $ua->agent($USER_AGENT);
        $ua->from($FROM_EMAIL);
        $ua->env_proxy;

        my $res = $ua->mirror( $uri, $to ) or return;

        if ( $res->code == 304 or $res->code == 200 ) {
            return $to;

        }
        else {
            return $self->_error(
                loc(
                    "Fetch failed! HTTP response: %1 %2 [%3]",
                    $res->code,
                    HTTP::Status::status_message( $res->code ),
                    $res->status_line
                )
            );
        }

    }
    else {
        $METHOD_FAIL->{'lwp'} = 1;
        return;
    }
}

sub _httptiny_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    my $use_list = {
        'HTTP::Tiny' => '0.008',

    };

    if ( can_load( modules => $use_list ) ) {

        my $uri = $self->uri;

        my $http =
          HTTP::Tiny->new( ( $TIMEOUT ? ( timeout => $TIMEOUT ) : () ) );

        my $rc = $http->mirror( $uri, $to );

        unless ( $rc->{success} ) {

            return $self->_error(
                loc(
                    "Fetch failed! HTTP response: %1 [%2]", $rc->{status},
                    $rc->{reason}
                )
            );

        }

        return $to;

    }
    else {
        $METHOD_FAIL->{'httptiny'} = 1;
        return;
    }
}

sub _httplite_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    my $use_list = {
        'HTTP::Lite' => '2.2',

    };

    if ( can_load( modules => $use_list ) ) {

        my $uri     = $self->uri;
        my $retries = 0;

      RETRIES: while ( $retries++ < 5 ) {

            my $http = HTTP::Lite->new();
            $http->{timeout} = $TIMEOUT if $TIMEOUT;
            $http->http11_mode(1);

            my $fh = FileHandle->new;

            unless ( $fh->open( $to, '>' ) ) {
                return $self->_error(
                    loc( "Could not open '%1' for writing: %2", $to, $! ) );
            }

            $fh->autoflush(1);

            binmode $fh;

            my $rc = $http->request(
                $uri,
                sub {
                    my ( $self, $dref, $cbargs ) = @_;
                    local $\;
                    print {$cbargs} $$dref;
                },
                $fh
            );

            close $fh;

            if ( $rc == 301 || $rc == 302 ) {
                my $loc;
              HEADERS: for ( $http->headers_array ) {
                    /Location: (\S+)/ and $loc = $1, last HEADERS;
                }
                if ( $loc =~ m!^/! ) {
                    $uri =~ s{^(\w+?://[^/]+)/.*$}{$1};
                    $uri .= $loc;
                }
                else {
                    $uri = $loc;
                }
                next RETRIES;
            }
            elsif ( $rc == 200 ) {
                return $to;
            }
            else {
                return $self->_error(
                    loc(
                        "Fetch failed! HTTP response: %1 [%2]", $rc,
                        $http->status_message
                    )
                );
            }

        }

        return $self->_error("Fetch failed! Gave up after 5 tries");

    }
    else {
        $METHOD_FAIL->{'httplite'} = 1;
        return;
    }
}

sub _iosock_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    my $use_list = {
        'IO::Socket::INET' => '0.0',
        'IO::Select'       => '0.0',
    };

    if ( can_load( modules => $use_list ) ) {
        my $sock = IO::Socket::INET->new(
            PeerHost => $self->host,
            ( $self->host =~ /:/ ? () : ( PeerPort => 80 ) ),
        );

        unless ($sock) {
            return $self->_error(
                loc( "Could not open socket to '%1', '%2'", $self->host, $! ) );
        }

        my $fh = FileHandle->new;

        unless ( $fh->open( $to, '>' ) ) {
            return $self->_error(
                loc( "Could not open '%1' for writing: %2", $to, $! ) );
        }

        $fh->autoflush(1);
        binmode $fh;

        my $path = File::Spec::Unix->catfile( $self->path, $self->file );
        my $req =
          "GET $path HTTP/1.0\x0d\x0aHost: " . $self->host . "\x0d\x0a\x0d\x0a";
        $sock->send($req);

        my $select = IO::Select->new($sock);

        my $resp   = '';
        my $normal = 0;
        while ( $select->can_read( $TIMEOUT || 60 ) ) {
            my $ret = $sock->sysread( $resp, 4096, length($resp) );
            if ( !defined $ret or $ret == 0 ) {
                $select->remove($sock);
                $normal++;
            }
        }
        close $sock;

        unless ($normal) {
            return $self->_error(
                loc(
                    "Socket timed out after '%1' seconds", ( $TIMEOUT || 60 )
                )
            );
        }

        $resp =~ s/^(\x0d?\x0a)+//;
        unless ( $resp =~ m!^HTTP/(\d+)\.(\d+)!i ) {
            return $self->_error(
                loc( "Did not get a HTTP response from '%1'", $self->host ) );
        }

        my ($code) = $resp =~ m!^HTTP/\d+\.\d+\s+(\d+)!i;
        unless ( $code eq '200' ) {
            return $self->_error(
                loc(
                    "Got a '%1' from '%2' expected '200'", $code, $self->host
                )
            );
        }

        {
            local $\;
            print $fh +( $resp =~ m/\x0d\x0a\x0d\x0a(.*)$/s )[0];
        }
        close $fh;
        return $to;

    }
    else {
        $METHOD_FAIL->{'iosock'} = 1;
        return;
    }
}

sub _netftp_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    my $use_list = { 'Net::FTP' => 0 };

    if ( can_load( modules => $use_list ) ) {

        my $ftp;
        my @options = ( $self->host );
        push( @options, Timeout => $TIMEOUT ) if $TIMEOUT;
        unless ( $ftp = Net::FTP->new(@options) ) {
            return $self->_error( loc( "Ftp creation failed: %1", $@ ) );
        }

        unless ( $ftp->login( anonymous => $FROM_EMAIL ) ) {
            return $self->_error(
                loc( "Could not login to '%1'", $self->host ) );
        }

        $ftp->binary;

        my $remote = File::Spec::Unix->catfile( $self->path, $self->file );

        my $target;
        unless ( $target = $ftp->get( $remote, $to ) ) {
            return $self->_error(
                loc( "Could not fetch '%1' from '%2'", $remote, $self->host ) );
        }

        $ftp->quit;

        return $target;

    }
    else {
        $METHOD_FAIL->{'netftp'} = 1;
        return;
    }
}

sub _wget_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    if ( my $wget = can_run('wget') ) {

        my $cmd = [ $wget, '--quiet' ];

        push( @$cmd, '--timeout=' . $TIMEOUT ) if $TIMEOUT;

        push @$cmd, '--passive-ftp' if $FTP_PASSIVE;

        push @$cmd, '--output-document', $to, $self->uri;

        my $captured;
        unless (
            run(
                command => $cmd,
                buffer  => \$captured,
                verbose => $DEBUG
            )
          )
        {
            1 while unlink $to;

            return $self->_error(
                loc( "Command failed: %1", $captured || '' ) );
        }

        return $to;

    }
    else {
        $METHOD_FAIL->{'wget'} = 1;
        return;
    }
}

sub _lftp_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    if ( my $lftp = can_run('lftp') ) {

        my $cmd = [ $lftp, '-f' ];

        my $fh = File::Temp->new;

        my $str;

        $str .= "set net:timeout $TIMEOUT;\n" if $TIMEOUT;

        $str .= "set ftp:passive-mode 1;\n" if $FTP_PASSIVE;

        $str .= q[get '] . $self->uri . q[' -o ] . $to . $/;

        if ($DEBUG) {
            my $pp_str = join ' ', split $/, $str;
            print "# lftp command: $pp_str\n";
        }

        $fh->autoflush(1);
        print $fh $str;

        push @$cmd, $fh->filename;

        my $captured;
        unless (
            run(
                command => $cmd,
                buffer  => \$captured,
                verbose => $DEBUG
            )
          )
        {
            1 while unlink $to;

            return $self->_error(
                loc( "Command failed: %1", $captured || '' ) );
        }

        return $to;

    }
    else {
        $METHOD_FAIL->{'lftp'} = 1;
        return;
    }
}

sub _ftp_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    if ( my $ftp = can_run('ftp') ) {

        my $fh = FileHandle->new;

        local $SIG{CHLD} = 'IGNORE';

        unless ( $fh->open("|$ftp -n") ) {
            return $self->_error( loc( "%1 creation failed: %2", $ftp, $! ) );
        }

        my @dialog = (
            "lcd " . dirname($to),
            "open " . $self->host,
            "user anonymous $FROM_EMAIL",
            "cd /",
            "cd " . $self->path,
            "binary",
            "get " . $self->file . " " . $self->output_file,
            "quit",
        );

        foreach (@dialog) { $fh->print( $_, "\n" ) }
        $fh->close or return;

        return $to;
    }
}

sub _lynx_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    if ( my $lynx = can_run('lynx') ) {

        unless ( IPC::Cmd->can_capture_buffer ) {
            $METHOD_FAIL->{'lynx'} = 1;

            return $self->_error(
                loc(
                    "Can not capture buffers. Can not use '%1' to fetch files",
                    'lynx'
                )
            );
        }

        if ( $self->uri =~ /^https?:\/\//i ) {
            my $cmd =
              [ $lynx, '-head', '-source', "-auth=anonymous:$FROM_EMAIL", ];

            push @$cmd, "-connect_timeout=$TIMEOUT" if $TIMEOUT;

            push @$cmd, $self->uri;

            my $head;
            unless (
                run(
                    command => $cmd,
                    buffer  => \$head,
                    verbose => $DEBUG
                )
              )
            {
                return $self->_error(
                    loc( "Command failed: %1", $head || '' ) );
            }

            unless ( $head =~ /^HTTP\/\d+\.\d+ 200\b/ ) {
                return $self->_error(
                    loc( "Command failed: %1", $head || '' ) );
            }
        }

        my $local = FileHandle->new(">$to")
          or return $self->_error(
            loc( "Could not open '%1' for writing: %2", $to, $! ) );

        my $cmd = [ $lynx, '-source', "-auth=anonymous:$FROM_EMAIL", ];

        push @$cmd, "-connect_timeout=$TIMEOUT" if $TIMEOUT;

        push @$cmd, $self->uri;

        my $captured;
        unless (
            run(
                command => $cmd,
                buffer  => \$captured,
                verbose => $DEBUG
            )
          )
        {
            return $self->_error(
                loc( "Command failed: %1", $captured || '' ) );
        }

        $local->print($captured);
        $local->close or return;

        return $to;

    }
    else {
        $METHOD_FAIL->{'lynx'} = 1;
        return;
    }
}

sub _ncftp_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    return if $FTP_PASSIVE;

    if ( my $ncftp = can_run('ncftp') ) {

        my $cmd = [
            $ncftp,
            '-V', '-p',
            $FROM_EMAIL, $self->host, dirname($to),  $IPC::Cmd::USE_IPC_RUN
            ? File::Spec::Unix->catdir( $self->path, $self->file )
            : QUOTE
              . File::Spec::Unix->catdir( $self->path, $self->file )
              . QUOTE

        ];

        my $captured;
        unless (
            run(
                command => $cmd,
                buffer  => \$captured,
                verbose => $DEBUG
            )
          )
        {
            return $self->_error(
                loc( "Command failed: %1", $captured || '' ) );
        }

        return $to;

    }
    else {
        $METHOD_FAIL->{'ncftp'} = 1;
        return;
    }
}

sub _curl_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    if ( my $curl = can_run('curl') ) {

        my $cmd = [ $curl, '-q' ];

        push( @$cmd, '--connect-timeout', $TIMEOUT ) if $TIMEOUT;

        push( @$cmd, '--silent' ) unless $DEBUG;

        if ( $self->scheme eq 'ftp' ) {
            push( @$cmd, '--user', "anonymous:$FROM_EMAIL" );
        }

        push @$cmd, '--fail', '--location', '--output', $to, $self->uri;

        my $captured;
        unless (
            run(
                command => $cmd,
                buffer  => \$captured,
                verbose => $DEBUG
            )
          )
        {

            return $self->_error(
                loc( "Command failed: %1", $captured || '' ) );
        }

        return $to;

    }
    else {
        $METHOD_FAIL->{'curl'} = 1;
        return;
    }
}

sub _fetch_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    if ( HAS_FETCH and my $fetch = can_run('fetch') ) {

        my $cmd = [ $fetch, '-q' ];

        push( @$cmd, '-T', $TIMEOUT ) if $TIMEOUT;

        local $ENV{'FTP_PASSIVE_MODE'} = 1 if $FTP_PASSIVE;

        push @$cmd, '-o', $to, $self->uri;

        my $captured;
        unless (
            run(
                command => $cmd,
                buffer  => \$captured,
                verbose => $DEBUG
            )
          )
        {
            1 while unlink $to;

            return $self->_error(
                loc( "Command failed: %1", $captured || '' ) );
        }

        return $to;

    }
    else {
        $METHOD_FAIL->{'wget'} = 1;
        return;
    }
}

sub _file_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    my $path  = $self->path;
    my $vol   = $self->vol;
    my $share = $self->share;

    my $remote;
    if ( !$share and $self->host ) {
        return $self->_error(
            loc(
                "Currently %1 cannot handle hosts in %2 urls", 'File::Fetch',
                'file://'
            )
        );
    }

    if ($vol) {
        $path = File::Spec->catdir( split /\//, $path );
        $remote = File::Spec->catpath( $vol, $path, $self->file );

    }
    elsif ($share) {
        $path =~ s|/+|\\|g;
        $remote = "\\\\" . $self->host . "\\$share\\$path";

    }
    else {
        my $file_class =
          ON_VMS
          ? 'File::Spec::Unix'
          : 'File::Spec';

        $remote = $file_class->catfile( $path, $self->file );
    }

    my $rv = eval { File::Copy::copy( $remote, $to ) };

    if ( !$rv or $@ ) {
        return $self->_error(
            loc( "Could not copy '%1' to '%2': %3 %4", $remote, $to, $!, $@ ) );
    }

    return $to;
}

sub _rsync_fetch {
    my $self = shift;
    my %hash = @_;

    my ($to);
    my $tmpl = { to => { required => 1, store => \$to } };
    check( $tmpl, \%hash ) or return;

    if ( my $rsync = can_run('rsync') ) {

        my $cmd = [$rsync];

        push( @$cmd, '--timeout=' . $TIMEOUT ) if $TIMEOUT;

        push( @$cmd, '--quiet' ) unless $DEBUG;

        push @$cmd, $self->uri, $to;

        my $captured;
        unless (
            run(
                command => $cmd,
                buffer  => \$captured,
                verbose => $DEBUG
            )
          )
        {

            return $self->_error(
                loc( "Command %1 failed: %2", "@$cmd" || '', $captured || '' )
            );
        }

        return $to;

    }
    else {
        $METHOD_FAIL->{'rsync'} = 1;
        return;
    }
}


sub _error {
    my $self  = shift;
    my $error = shift;

    $self->_error_msg($error);
    $self->_error_msg_long( Carp::longmess($error) );

    if ($WARN) {
        carp $DEBUG ? $self->_error_msg_long : $self->_error_msg;
    }

    return;
}

sub error {
    my $self = shift;
    return shift() ? $self->_error_msg_long : $self->_error_msg;
}

1;


