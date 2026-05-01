package Module::Load::Conditional;

use strict;

use Module::Load;
use Params::Check qw[check];
use Locale::Maketext::Simple Style => 'gettext';

use Carp       ();
use File::Spec ();
use FileHandle ();
use version;

use constant ON_VMS => $^O eq 'VMS';

BEGIN {
    use vars qw[ $VERSION @ISA $VERBOSE $CACHE @EXPORT_OK $DEPRECATED
      $FIND_VERSION $ERROR $CHECK_INC_HASH];
    use Exporter;
    @ISA            = qw[Exporter];
    $VERSION        = '0.46';
    $VERBOSE        = 0;
    $DEPRECATED     = 0;
    $FIND_VERSION   = 1;
    $CHECK_INC_HASH = 0;
    @EXPORT_OK      = qw[check_install can_load requires];
}


sub check_install {
    my %hash = @_;

    my $tmpl = {
        version => { default  => '0.0' },
        module  => { required => 1 },
        verbose => { default  => $VERBOSE },
    };

    my $args;
    unless ( $args = check( $tmpl, \%hash, $VERBOSE ) ) {
        warn loc(q[A problem occurred checking arguments]) if $VERBOSE;
        return;
    }

    my $file = File::Spec->catfile( split /::/, $args->{module} ) . '.pm';
    my $file_inc =
      File::Spec::Unix->catfile( split /::/, $args->{module} ) . '.pm';

    my $href = {
        file     => undef,
        version  => undef,
        uptodate => undef,
    };

    my $filename;

    if ($CHECK_INC_HASH) {
        $filename = $href->{'file'} = $INC{$file_inc}
          if defined $INC{$file_inc};

        if ( defined $filename && $FIND_VERSION ) {
            no strict 'refs';
            $href->{version} = ${ "$args->{module}" . "::VERSION" };
        }
    }

    unless ($filename) {

      DIR: for my $dir (@INC) {

            my $fh;

            if ( ref $dir ) {

                my $existed_in_inc = $INC{$file_inc};

                if ( UNIVERSAL::isa( $dir, 'CODE' ) ) {
                    ($fh) = $dir->( $dir, $file );

                }
                elsif ( UNIVERSAL::isa( $dir, 'ARRAY' ) ) {
                    ($fh) = $dir->[0]->( $dir, $file, @{$dir}{ 1 .. $#{$dir} } )

                }
                elsif ( UNIVERSAL::can( $dir, 'INC' ) ) {
                    ($fh) = $dir->INC($file);
                }

                if ( !UNIVERSAL::isa( $fh, 'GLOB' ) ) {
                    warn loc( q[Cannot open file '%1': %2], $file, $! )
                      if $args->{verbose};
                    next;
                }

                $filename = $INC{$file_inc} || $file;

                delete $INC{$file_inc} if not $existed_in_inc;

            }
            else {
                $filename = File::Spec->catfile( $dir, $file );
                next unless -e $filename;

                $fh = new FileHandle;
                if ( !$fh->open($filename) ) {
                    warn loc( q[Cannot open file '%1': %2], $file, $! )
                      if $args->{verbose};
                    next;
                }
            }

            $href->{dir} = $dir;

            $href->{file} =
              ON_VMS
              ? VMS::Filespec::unixify($filename)
              : $filename;

            if ($FIND_VERSION) {

                my $in_pod = 0;
                while ( my $line = <$fh> ) {

                    $in_pod =
                        $line =~ /^=(?!cut)/ ? 1
                      : $line =~ /^=cut/     ? 0
                      :                        $in_pod;
                    next if $in_pod;

                    my $ver = __PACKAGE__->_parse_version($line);

                    if ( defined $ver ) {
                        $href->{version} = $ver;

                        last DIR;
                    }
                }
            }
        }
    }

    return unless defined $href->{file};

    if ( $FIND_VERSION and not defined $href->{version} ) {
        { local $^W;

            warn loc( q[Could not check version on '%1'], $args->{module} )
              if $args->{verbose} and $args->{version} > 0;
        }
        $href->{uptodate} = 1;

    }
    else {
        local $^W;

        eval {

            $href->{uptodate} =
              version->new( $args->{version} ) <=
              version->new( $href->{version} )
              ? 1
              : 0;

        };
    }

    if ( $DEPRECATED and version->new($]) >= version->new('5.011') ) {
        require Module::CoreList;
        require Config;

        $href->{uptodate} = 0
          if exists $Module::CoreList::version{ 0 + $] }{ $args->{module} }
          and Module::CoreList::is_deprecated( $args->{module} )
          and $Config::Config{privlibexp} eq $href->{dir};
    }

    return $href;
}

sub _parse_version {
    my $self    = shift;
    my $str     = shift or return;
    my $verbose = shift || 0;

    return unless $str =~ /VERSION/;

    return if $str =~ /^\s*#/;

    my $taint_safe_str = do { $str =~ /(^.*$)/sm; $1 };

    if ( $str =~ /(?<!\\)([\$*])(([\w\:\']*)\bVERSION)\b.*\=/ ) {

        print "Evaluating: $str\n" if $verbose;

        my $eval = qq{
            package Module::Load::Conditional::_version;
            no strict;

            local $1$2;
            \$$2=undef; do {
                $taint_safe_str
            }; \$$2
        };

        print "Evaltext: $eval\n" if $verbose;

        my $result = do {
            local $^W = 0;
            eval($eval);
        };

        my $rv = defined $result ? $result : '0.0';

        print( $@ ? "Error: $@\n" : "Result: $rv\n" ) if $verbose;

        return $rv;
    }

    return;
}


sub can_load {
    my %hash = @_;

    my $tmpl = {
        modules => { default => {}, strict_type => 1 },
        verbose => { default => $VERBOSE },
        nocache => { default => 0 },
    };

    my $args;

    unless ( $args = check( $tmpl, \%hash, $VERBOSE ) ) {
        $ERROR = loc(q[Problem validating arguments!]);
        warn $ERROR if $VERBOSE;
        return;
    }

    $CACHE ||= {};

    my $error;
  BLOCK: {
        my $href = $args->{modules};

        my @load;
        for my $mod ( keys %$href ) {

            next if $CACHE->{$mod}->{usable} && !$args->{nocache};

            if (
                   !$args->{nocache}
                && defined $CACHE->{$mod}->{usable}
                && ( version->new( $CACHE->{$mod}->{version} || 0 ) >=
                    version->new( $href->{$mod} ) )
              )
            {
                $error =
                  loc( q[Already tried to use '%1', which was unsuccessful],
                    $mod );
                last BLOCK;
            }

            my $mod_data = check_install(
                module  => $mod,
                version => $href->{$mod}
            );

            if ( !$mod_data or !defined $mod_data->{file} ) {
                $error = loc( q[Could not find or check module '%1'], $mod );
                $CACHE->{$mod}->{usable} = 0;
                last BLOCK;
            }

            map { $CACHE->{$mod}->{$_} = $mod_data->{$_} }
              qw[version file uptodate];

            push @load, $mod;
        }

        for my $mod (@load) {

            if ( $CACHE->{$mod}->{uptodate} ) {

                eval { load $mod };

                if ($@) {
                    $error = $@;
                    $CACHE->{$mod}->{usable} = 0;
                    last BLOCK;
                }
                else {
                    $CACHE->{$mod}->{usable} = 1;
                }

            }
            else {

                $error = loc( q[Module '%1' is not uptodate!], $mod );
                $CACHE->{$mod}->{usable} = 0;
                last BLOCK;
            }
        }

    }

    if ( defined $error ) {
        $ERROR = $error;
        Carp::carp( loc( q|%1 [THIS MAY BE A PROBLEM!]|, $error ) )
          if $args->{verbose};
        return;
    }
    else {
        return 1;
    }
}


sub requires {
    my $who = shift;

    unless ( check_install( module => $who ) ) {
        warn loc( q[You do not have module '%1' installed], $who ) if $VERBOSE;
        return undef;
    }

    my $lib = join " ", map { qq["-I$_"] } @INC;
    my $cmd = qq[$^X $lib -M$who -e"print(join(qq[\\n],keys(%INC)))"];

    return sort
      grep { !/^$who$/ }
      map { chomp; s|/|::|g; $_ }
      grep { s|\.pm$||i; } `$cmd`;
}

1;

__END__

