package CPANPLUS::Internals;

use 5.006001;

use strict;
use Config;

use CPANPLUS::Error;

use CPANPLUS::Selfupdate;

use CPANPLUS::Internals::Extract;
use CPANPLUS::Internals::Fetch;
use CPANPLUS::Internals::Utils;
use CPANPLUS::Internals::Constants;
use CPANPLUS::Internals::Search;
use CPANPLUS::Internals::Report;

require base;
use Cwd qw[cwd];
use Module::Load qw[load];
use Params::Check qw[check];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';
use Module::Load::Conditional qw[can_load];

use Object::Accessor;

local $Params::Check::VERBOSE = 1;

use vars qw[@ISA $VERSION];

@ISA = qw[
  CPANPLUS::Internals::Extract
  CPANPLUS::Internals::Fetch
  CPANPLUS::Internals::Utils
  CPANPLUS::Internals::Search
  CPANPLUS::Internals::Report
];

$VERSION = "0.9121";


for my $key (
    qw[_conf _id _modules _hosts _methods _status
    _callbacks _selfupdate _mtree _atree]
  )
{
    no strict 'refs';
    *{ __PACKAGE__ . "::$key" } = sub {
        $_[0]->{$key} = $_[1] if @_ > 1;
        return $_[0]->{$key};
      }
}


{ my $callback_map = {
        install_prerequisite => 1, edit_test_report => 0, send_test_report =>
          1,  munge_test_report => sub { return $_[1] },
        filter_prereqs          => sub { return $_[1] },
        proceed_on_test_failure => sub { return 0 },
        munge_dist_metafile     => sub { return $_[1] },
    };

    my $status = Object::Accessor->new;
    $status->mk_accessors(qw[pending_prereqs]);

    my $callback = Object::Accessor->new;
    $callback->mk_accessors( keys %$callback_map );

    my $conf;
    my $Tmpl = {
        _conf => {
            required => 1,
            store    => \$conf,
            allow    => IS_CONFOBJ
        },
        _id         => { default => '',        no_override => 1 },
        _authortree => { default => '',        no_override => 1 },
        _modtree    => { default => '',        no_override => 1 },
        _hosts      => { default => {},        no_override => 1 },
        _methods    => { default => {},        no_override => 1 },
        _status     => { default => '<empty>', no_override => 1 },
        _callbacks  => { default => '<empty>', no_override => 1 },
    };

    sub _init {
        my $class = shift;
        my %hash  = @_;

        if ( my $id = $class->_last_id ) {
            warn loc(
                q[%1 currently only supports one %2 object per ]
                  . qq[running program\n],
                'CPANPLUS', $class
            );

            return $class->_retrieve_id($id);
        }

        my $args = check( $Tmpl, \%hash )
          or die loc( qq[Could not initialize '%1' object], $class );

        bless $args, $class;

        $args->{'_id'}        = $args->_inc_id;
        $args->{'_status'}    = $status;
        $args->{'_callbacks'} = $callback;

        for my $name ( $callback->ls_accessors ) {
            my $rv =
                ref $callback_map->{$name} ? 'sub return value'
              : $callback_map->{$name}     ? 'true'
              :                              'false';

            $args->_callbacks->$name(
                sub {
                    msg(
                        loc(
                            "DEFAULT '%1' HANDLER RETURNING '%2'", $name, $rv
                        ),
                        $args->_conf->get_conf('debug')
                    );
                    return
                      ref $callback_map->{$name}
                      ? $callback_map->{$name}->(@_)
                      : $callback_map->{$name};
                }
            );
        }

        $args->_selfupdate( CPANPLUS::Selfupdate->new($args) );

        $args->_status->pending_prereqs( {} );

        $conf->_set_build( startdir => cwd() ),
          or error( loc("couldn't locate current dir!") );

        $ENV{FTP_PASSIVE} = 1, if $conf->get_conf('passive');

        my $id = $args->_store_id($args);

        unless ( $id == $args->_id ) {
            error(
                loc(
                    "IDs do not match: %1 != %2. Storage failed!", $id,
                    $args->_id
                )
            );
        }

        {
            my $store = $conf->get_conf('source_engine')
              || DEFAULT_SOURCE_ENGINE;

            unless ( can_load( modules => { $store => '0.0' }, verbose => 1 ) )
            {
                error( loc( "Could not load source engine '%1'", $store ) );

                if ( $store ne DEFAULT_SOURCE_ENGINE ) {
                    msg( loc( "Falling back to %1", DEFAULT_SOURCE_ENGINE ),
                        1 );

                    load DEFAULT_SOURCE_ENGINE;

                    base->import(DEFAULT_SOURCE_ENGINE);
                }
                else {
                    return;
                }
            }
            else {
                base->import($store);
            }
        }

        return $args;
    }


    sub _flush {
        my $self = shift;
        my $conf = $self->configure_object;
        my %hash = @_;

        my $aref;
        my $tmpl = {
            list => {
                required    => 1,
                default     => [],
                strict_type => 1,
                store       => \$aref
            },
        };

        my $args = check( $tmpl, \%hash ) or return;

        my $flag = 0;
        for my $what (@$aref) {
            my $cache = '_' . $what;

            if ( $what eq 'lib' ) {
                $ENV{PERL5LIB} = $conf->_perl5lib || '';
                @INC = @{ $conf->_lib };

            }
            elsif ( $what eq 'modules' ) {
                for my $modobj ( values %{ $self->module_tree } ) {

                    $modobj->_flush;
                }

            }
            elsif ( $what eq 'methods' ) {

                $File'Fetch::METHOD_FAIL = $File'Fetch::METHOD_FAIL = {};

            }
            elsif ( $what eq 'load' ) {
                undef $Module::Load::Conditional::CACHE;

            }
            else {
                unless ( exists $self->{$cache} && exists $Tmpl->{$cache} ) {
                    error( loc( "No such cache: '%1'", $what ) );
                    $flag++;
                    next;
                }
                else {
                    $self->$cache( {} );
                }
            }
        }
        return !$flag;
    }


    sub _register_callback {
        my $self = shift or return;
        my %hash = @_;

        my ( $name, $code );
        my $tmpl = {
            name => {
                required => 1,
                store    => \$name,
                allow    => [ $callback->ls_accessors ]
            },
            code => {
                required => 1,
                allow    => IS_CODEREF,
                store    => \$code
            },
        };

        check( $tmpl, \%hash ) or return;

        $self->_callbacks->$name($code) or return;

        return 1;
    }

}


sub _add_to_includepath {
    my $self = shift;
    my %hash = @_;

    my $dirs;
    my $tmpl = {
        directories => {
            required    => 1,
            default     => [],
            store       => \$dirs,
            strict_type => 1
        },
    };

    check( $tmpl, \%hash ) or return;

    my $s = $Config{'path_sep'};

    for my $lib (@$dirs) {
        push @INC, $lib unless grep { $_ eq $lib } @INC;
        local $^W;
        $ENV{'PERL5LIB'} .= $s . $lib
          unless $ENV{'PERL5LIB'} =~ qr|\Q$s$lib\E|;
    }

    return 1;
}


{
    my $idref = {};
    my $count = 0;

    sub _inc_id { return ++$count; }

    sub _last_id { $count }

    sub _store_id {
        my $self = shift;
        my $obj = shift or return;

        unless ( IS_INTERNALS_OBJ->($obj) ) {
            error(
                loc(
                    "The object you passed has the wrong ref type: '%1'",
                    ref $obj
                )
            );
            return;
        }

        $idref->{ $obj->_id } = $obj;
        return $obj->_id;
    }

    sub _retrieve_id {
        my $self = shift;
        my $id = shift or return;

        my $obj = $idref->{$id};
        return $obj;
    }

    sub _remove_id {
        my $self = shift;
        my $id = shift or return;

        return delete $idref->{$id};
    }

    sub _return_all_objects { return values %$idref }
}

1;

