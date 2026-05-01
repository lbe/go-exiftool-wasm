package CPANPLUS::Internals::Fetch;

use strict;

use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;

use File::Fetch;
use File::Spec;
use Cwd qw[cwd];
use IPC::Cmd qw[run];
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

$Params::Check::VERBOSE = 1;



sub _fetch {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    local $Params::Check::NO_DUPLICATES = 0;

    my ( $modobj, $verbose, $force, $fetch_from, $ttl );
    my $tmpl = {
        module => { required => 1, allow => IS_MODOBJ, store => \$modobj },
        fetchdir   => { default => $conf->get_conf('fetchdir') },
        fetch_from => { default => '', store => \$fetch_from },
        force => {
            default => $conf->get_conf('force'),
            store   => \$force
        },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        prefer_bin => { default => $conf->get_conf('prefer_bin') },
        ttl        => { default => 0, store => \$ttl },
    };

    my $args = check( $tmpl, \%hash ) or return;

    if ( ( my $where = $modobj->status->fetch() ) and not $force and not $ttl )
    {

        msg(
            loc(
                "Already fetched '%1' to '%2', "
                  . "won't fetch again without force",
                $modobj->module,
                $where
            ),
            $verbose
        );
        return $where;
    }

    my ( $remote_file, $local_file, $local_path );

    {
        $local_path = $args->{fetchdir}
          || File::Spec->catdir( $conf->get_conf('base'), $modobj->path, );

        unless ( -d $local_path ) {
            unless ( $self->_mkdir( dir => $local_path ) ) {
                msg( loc( "Could not create path '%1'", $local_path ),
                    $verbose );
                return;
            }
        }

        $local_file =
          File::Spec->rel2abs(
            File::Spec->catfile( $local_path, $modobj->package, ) );

        if ( -e $local_file ) {

            my $unlink     = 0;
            my $use_cached = 0;

            if ($force) {
                $unlink++

            }
            elsif ( $ttl and ( [ stat $local_file ]->[9] + $ttl > time ) ) {
                msg(
                    loc(
                        "Using cached file '%1' on disk; "
                          . "ttl (%2s) is not exceeded",
                        $local_file,
                        $ttl
                    ),
                    $verbose
                );

                $use_cached++;

            }
            elsif ($ttl) {
                $unlink++;

            }
            else {
                $use_cached++;
            }

            if ($unlink) {
                1 while unlink $local_file;

                msg(
                    loc(
                        "Could not delete %1, some methods may "
                          . "fail to force a download",
                        $local_file
                    ),
                    $verbose
                ) if -e $local_file;

            }
            else {

                $modobj->status->fetch($local_file);

                return $local_file;
            }
        }
    }

    if ($fetch_from) {
        my $abs = $self->__file_fetch(
            from    => $fetch_from,
            to      => $local_path,
            verbose => $verbose
        );

        unless ($abs) {
            error( loc( "Unable to download '%1'", $fetch_from ) );
            return;
        }

        $modobj->status->fetch($abs);

        return $abs;

    }
    else {
        {
            $remote_file =
              File::Spec::Unix->catfile( $modobj->path, $modobj->package, );
            unless ($remote_file) {
                error( loc('No remote file given for download') );
                return;
            }
        }

        my $found_host;
        my @maybe_bad_host;

      HOST: {

            local $File'Fetch::BLACKLIST   = $conf->_get_fetch('blacklist');
            local $File'Fetch::TIMEOUT     = $conf->get_conf('timeout');
            local $File'Fetch::DEBUG       = $conf->get_conf('debug');
            local $File'Fetch::FTP_PASSIVE = $conf->get_conf('passive');
            local $File'Fetch::FROM_EMAIL  = $conf->get_conf('email');
            local $File'Fetch::PREFER_BIN  = $conf->get_conf('prefer_bin');
            local $File'Fetch::WARN        = $verbose;

            for my $host ( @{ $conf->get_conf('hosts') } ) {
                $found_host++;

                my $where;

                if ( $host->{'scheme'} eq 'file' ) {

                    my $host_spec =
                      File::Spec->file_name_is_absolute( $host->{'path'} )
                      ? $host->{'path'}
                      : File::Spec->rel2abs( $host->{'path'} );

                    if ( ON_WIN32 or ON_VMS ) {

                        my ( $vol, $host_path ) =
                          File::Spec->splitpath( $host_spec, 'no_file' );

                        my @host_dirs = File::Spec->splitdir($host_path);

                        if ( defined $vol and $vol ) {

                            $vol =~ s/:$/|/ if ON_WIN32;

                            $vol =~ s/:// if ON_VMS;

                            if ( $host_dirs[0] ) {
                                unshift @host_dirs, $vol;

                            }
                            else {
                                $host_dirs[0] = $vol;
                            }
                        }

                        $host_spec = File::Spec::Unix->catdir(@host_dirs);
                    }

                    $where = CREATE_FILE_URI->(
                        File::Spec::Unix->catfile(
                            $host->{'host'} || '',
                            $host_spec, $remote_file,
                        )
                    );

                }
                else {
                    my $mirror_path =
                      File::Spec::Unix->catfile( $host->{'path'},
                        $remote_file );

                    my %args = (
                        scheme => $host->{scheme},
                        host   => $host->{host},
                        path   => $mirror_path,
                    );

                    $where = $self->_host_to_uri(%args);
                }

                my $abs = $self->__file_fetch(
                    from    => $where,
                    to      => $local_path,
                    verbose => $verbose
                );

                if ($abs) {
                    $modobj->status->fetch($abs);

                    $self->_add_fail_host( host => $_ ) for @maybe_bad_host;

                    return $abs;
                }

                push @maybe_bad_host, $host;
            }
        }

        $found_host
          ? error(
            loc(
                    "Fetch failed: host list exhausted "
                  . "-- are you connected today?"
            )
          )
          : error(
            loc( "No hosts found to download from " . "-- check your config" )
          );
    }

    return;
}

sub __file_fetch {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my ( $where, $local_path, $verbose );
    my $tmpl = {
        from    => { required => 1, store => \$where },
        to      => { required => 1, store => \$local_path },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
    };

    check( $tmpl, \%hash ) or return;

    msg( loc( "Trying to get '%1'", $where ), $verbose );

    my $ff = File::Fetch->new( uri => $where );

    error( loc( "Bad uri '%1'", $where ) ), return unless $ff;

    if ( my $file = $ff->fetch( to => $local_path ) ) {
        unless ( -e $file && -s _ ) {
            msg(
                loc(
                    "'%1' said it fetched '%2', but it was not created",
                    'File::Fetch', $file
                ),
                $verbose
            );

        }
        else {
            my $abs = File::Spec->rel2abs($file);

            $self->_update_timestamp( file => $abs );

            return $abs;
        }

    }
    else {
        error( loc( "Fetching of '%1' failed: %2", $where, $ff->error ) );
    }

    return;
}


{

    sub _add_fail_host {
        my $self = shift;
        my %hash = @_;

        my $host;
        my $tmpl = {
            host => {
                required    => 1,
                default     => {},
                strict_type => 1,
                store       => \$host
            },
        };

        check( $tmpl, \%hash ) or return;

        return $self->_hosts->{$host} = 1;
    }

    sub _host_ok {
        my $self = shift;
        my %hash = @_;

        my $host;
        my $tmpl = { host => { required => 1, store => \$host }, };

        check( $tmpl, \%hash ) or return;

        return $self->_hosts->{$host} ? 0 : 1;
    }
}

1;

