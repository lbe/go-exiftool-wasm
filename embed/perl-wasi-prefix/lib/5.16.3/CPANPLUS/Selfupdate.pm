package CPANPLUS::Selfupdate;

use strict;
use Params::Check qw[check];
use IPC::Cmd qw[can_run];
use CPANPLUS::Error qw[error msg];
use Module::Load::Conditional qw[check_install];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

use CPANPLUS::Internals::Constants;

$Params::Check::VERBOSE = 1;


{

    my $Modules = {
        dependencies => {
            'File::Fetch'  => '0.15_02', 'File::Spec'               => '0.82',
            'IPC::Cmd'     => '0.36',    'Locale::Maketext::Simple' => '0.01',
            'Log::Message' => '0.01',
            'Module::Load' => '0.10',
            'Module::Load::Conditional' => '0.38',  'version' =>
              '0.77',    'Params::Check' => '0.22',
            'Package::Constants' => '0.01',
            'Term::UI' => '0.18', 'Test::Harness' => '2.62',  'Test::More' =>
              '0.47', 'Archive::Extract' => '0.16', 'Archive::Tar' => '1.23',
            'IO::Zlib' => '1.04', 'Object::Accessor' =>
              '0.34', 'Module::CoreList' => '2.22', 'Module::Pluggable' =>
              '2.4',
            'Module::Loaded'    => '0.01',
            'Parse::CPAN::Meta' => '1.4200', 'ExtUtils::Install' => '1.42', (
                check_install( module => 'CPANPLUS::Dist::Build' )
                ? ( 'CPANPLUS::Dist::Build' => '0.60' )
                : ()
            ),
        },

        features => {
            prefer_makefile => [
                sub {
                    my $cb = shift;
                    $cb->configure_object->get_conf('prefer_makefile')
                      ? {}
                      : { 'CPANPLUS::Dist::Build' => '0.60' };
                },
                sub { return 1 }, ],
            cpantest => [
                {
                    'Test::Reporter'    => '1.34',
                    'Parse::CPAN::Meta' => '1.4200'
                },
                sub {
                    my $cb = shift;
                    return $cb->configure_object->get_conf('cpantest');
                },
            ],
            dist_type => [
                sub {
                    my $cb   = shift;
                    my $dist = $cb->configure_object->get_conf('dist_type');
                    return { $dist => '0.0' } if $dist;
                    return;
                },
                sub {
                    my $cb = shift;
                    return $cb->configure_object->get_conf('dist_type');
                },
            ],

            md5 => [
                { 'Digest::SHA' => '0.0', },
                sub {
                    my $cb = shift;
                    return $cb->configure_object->get_conf('md5');
                },
            ],
            shell => [
                sub {
                    my $cb   = shift;
                    my $dist = $cb->configure_object->get_conf('shell');

                    return if $dist eq SHELL_DEFAULT or $dist eq SHELL_CLASSIC;
                    return { $dist => '0.0' } if $dist;
                    return;
                },
                sub { return 1 },
            ],
            signature => [
                sub {
                    my $cb = shift;
                    return { 'Module::Signature' => '0.06', } if can_run('gpg');

                    return {
                        'Crypt::OpenPGP'    => '0.0',
                        'Module::Signature' => '0.06',
                    };
                },
                sub {
                    my $cb = shift;
                    return $cb->configure_object->get_conf('signature');
                },
            ],
            storable => [
                { 'Storable' => '0.0' },
                sub {
                    my $cb = shift;
                    return $cb->configure_object->get_conf('storable');
                },
            ],
            sqlite_backend => [
                {
                    'DBIx::Simple' => '0.0',
                    'DBD::SQLite'  => '0.0',
                },
                sub {
                    my $cb   = shift;
                    my $conf = $cb->configure_object;
                    return $conf->get_conf('source_engine') eq
                      'CPANPLUS::Internals::Source::SQLite';
                },
            ],
        },
        core => { 'CPANPLUS' => '0.0', },
    };

    sub _get_config { return $Modules }
}


sub new {
    my $class = shift;
    my $cb = shift or return;
    return bless sub { $cb }, $class;
}

{ my $cache = {
        core => sub {
            my $self = shift;
            core => [ $self->list_core_modules ];
        },

        dependencies => sub {
            my $self = shift;
            dependencies => [ $self->list_core_dependencies ];
        },

        enabled_features => sub {
            my $self = shift;
            map { $_ => [ $self->modules_for_feature($_) ] }
              $self->list_enabled_features;
        },
        features => sub {
            my $self = shift;
            map { $_ => [ $self->modules_for_feature($_) ] }
              $self->list_features;
        },
        all => [qw|core dependencies enabled_features|],
    };


    sub list_categories { return sort keys %$cache }


    sub list_modules_to_update {
        my $self = shift;
        my $cb   = $self->();
        my $conf = $cb->configure_object;
        my %hash = @_;

        my ( $type, $latest );
        my $tmpl = {
            update => {
                required => 1,
                store    => \$type,
                allow    => [ keys %$cache ],
            },
            latest => { default => 0, store => \$latest, allow => BOOLEANS },
        };

        {
            local $Params::Check::ALLOW_UNKNOWN = 1;
            check( $tmpl, \%hash ) or return;
        }

        my $ref = $cache->{$type};

        my %list =
          UNIVERSAL::isa( $ref, 'ARRAY' )
          ? map { $cache->{$_}->($self) } @$ref
          : $ref->($self);

        for my $aref ( values %list ) {
            $aref = [
                $latest
                ? grep { !$_->is_uptodate } @$aref
                : grep { !$_->is_installed_version_sufficient } @$aref
            ];
        }

        return %list;
    }


    sub selfupdate {
        my $self = shift;
        my $cb   = $self->();
        my $conf = $cb->configure_object;
        my %hash = @_;

        my $force;
        my $tmpl =
          { force => { default => $conf->get_conf('force'), store => \$force },
          };

        {
            local $Params::Check::ALLOW_UNKNOWN = 1;
            check( $tmpl, \%hash ) or return;
        }

        my %list = $self->list_modules_to_update(%hash) or return;

        my @mods = map { @$_ } values %list;

        my $flag;
        for my $mod (@mods) {
            unless ( $mod->install( force => $force ) ) {
                $flag++;
                error( loc( "Failed to update module '%1'", $mod->name ) );
            }
        }

        return if $flag;
        return 1;
    }

}


sub list_features {
    my $self = shift;
    return keys %{ $self->_get_config->{'features'} };
}


sub list_enabled_features {
    my $self = shift;
    my $cb   = $self->();

    my @enabled;
    for my $feat ( $self->list_features ) {
        my $ref = $self->_get_config->{'features'}->{$feat}->[1];
        push @enabled, $feat if $ref->($cb);
    }

    return @enabled;
}


sub modules_for_feature {
    my $self    = shift;
    my $feature = shift or return;
    my $as_hash = shift || 0;
    my $cb      = $self->();

    unless ( exists $self->_get_config->{'features'}->{$feature} ) {
        error( loc( "Unknown feature '%1'", $feature ) );
        return;
    }

    my $ref = $self->_get_config->{'features'}->{$feature}->[0];

    my $href = UNIVERSAL::isa( $ref, 'HASH' ) ? $ref : $ref->($cb);

    return unless $href;

    return $href if $as_hash;
    return $self->_hashref_to_module($href);
}


sub list_core_dependencies {
    my $self    = shift;
    my $as_hash = shift || 0;
    my $cb      = $self->();
    my $href    = $self->_get_config->{'dependencies'};

    return $href if $as_hash;
    return $self->_hashref_to_module($href);
}


sub list_core_modules {
    my $self    = shift;
    my $as_hash = shift || 0;
    my $cb      = $self->();
    my $href    = $self->_get_config->{'core'};

    return $href if $as_hash;
    return $self->_hashref_to_module($href);
}

sub _hashref_to_module {
    my $self = shift;
    my $cb   = $self->();
    my $href = shift or return;

    return map {
        CPANPLUS::Selfupdate::Module->new( $cb->module_tree($_) => $href->{$_} )
    } keys %$href;
}


{

    package CPANPLUS::Selfupdate::Module;
    use base 'CPANPLUS::Module';

    my %Cache = ();
    my $Acc   = 'version_required';

    sub new {
        my $class = shift;
        my $mod   = shift or return;
        my $ver   = shift;
        return unless defined $ver;

        my $obj = $mod->clone;
        bless $obj, $class;

        $obj->$Acc($ver);

        return $obj;
    }


    sub version_required {
        my $self = shift;
        $Cache{ $self->name } = shift() if @_;
        return $Cache{ $self->name };
    }


    sub is_installed_version_sufficient {
        my $self = shift;
        return $self->is_uptodate( version => $self->$Acc );
    }

}

1;


