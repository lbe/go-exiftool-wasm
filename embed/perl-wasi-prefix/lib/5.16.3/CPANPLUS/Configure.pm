package CPANPLUS::Configure;
use strict;

use CPANPLUS::Internals::Constants;
use CPANPLUS::Error;
use CPANPLUS::Config;

use Log::Message;
use Module::Load qw[load];
use Params::Check qw[check];
use File::Basename qw[dirname];
use Module::Loaded ();
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

use vars qw[$AUTOLOAD $VERSION $MIN_CONFIG_VERSION];
use base qw[CPANPLUS::Internals::Utils];

local $Params::Check::VERBOSE = 1;

require CPANPLUS::Internals;
$VERSION = $CPANPLUS::Internals::VERSION = $CPANPLUS::Internals::VERSION;

for my $meth (qw[conf _lib _perl5lib]) {
    no strict 'refs';

    *$meth = sub {
        my $self = shift;
        $self->{ '_' . $meth } = $_[0] if @_;
        return $self->{ '_' . $meth };
      }
}


{
    my $Config;

    sub new {
        my $class = shift;
        my %hash  = @_;

        my ($load);
        my $tmpl = { load_configs => { default => 1, store => \$load }, };

        check( $tmpl, \%hash ) or ( warn Params::Check->last_error, return );

        $Config ||= CPANPLUS::Config->new;
        my $self = bless {}, $class;
        $self->conf($Config);

        $self->init if $load;

        $self->_lib( \@INC );
        $self->_perl5lib( $ENV{'PERL5LIB'} );

        return $self;
    }
}


{
    my $loaded;
    my $warned;

    sub init {
        my $self = shift;
        my $obj  = $self->conf;
        my %hash = @_;

        my ($rescan);
        my $tmpl = { rescan => { default => 0, store => \$rescan }, };

        check( $tmpl, \%hash ) or ( warn Params::Check->last_error, return );

        my $cur_base = $self->get_conf('base');

        {
            my $env = ENV_CPANPLUS_CONFIG;
            if ( $ENV{$env} and not $warned ) {
                $warned++;
                error(
                    loc(
                        "Specifying a config file in your environment "
                          . "using %1 is obsolete.\nPlease follow the "
                          . "directions outlined in %2 or use the '%3' command\n"
                          . "in the default shell to use custom config files.",
                        $env,
                        "CPANPLUS::Configure->save",
                        's save'
                    )
                );
            }
        }

        { local @INC = ( LIB_DIR->($cur_base), @INC );

            if ( !$loaded++ or $rescan ) {
                require Module::Pluggable;

                Module::Pluggable->import(
                    search_path => ['CPANPLUS::Config'],
                    search_dirs => [ LIB_DIR->($cur_base) ],
                    except      => qr/::SUPER$/,
                    sub_name    => 'configs'
                );
            }

            my %confs = map { $_ => $_ }
              grep { $_ !~ /::ISA::/ } __PACKAGE__->configs;
            my @confs = grep { defined }
              map { delete $confs{$_} } CONFIG_SYSTEM, CONFIG_USER;
            push @confs, sort keys %confs;

            for my $plugin (@confs) {
                msg( loc( "Found config '%1'", $plugin ), 0 );

                if ( my $loc = Module::Loaded::is_loaded($plugin) ) {
                    msg( loc( "  Already loaded '%1' (%2)", $plugin, $loc ),
                        0 );
                    next;
                }
                else {
                    msg( loc( "  Loading config '%1'", $plugin ), 0 );

                    if ( eval { load $plugin; 1 } ) {
                        msg(
                            loc(
                                "  Loaded '%1' (%2)", $plugin,
                                Module::Loaded::is_loaded($plugin)
                            ),
                            0
                        );
                    }
                    else {
                        error( loc( "  Error loading '%1': %2", $plugin, $@ ) );
                    }
                }

                if ($@) {
                    error( loc( "Could not load '%1': %2", $plugin, $@ ) );
                    next;
                }

                my $sub = $plugin->can('setup');
                $sub->($self) if $sub;
            }
        }

        if ( $cur_base ne $self->get_conf('base') ) {
            msg(
                loc(
                    "Base dir changed from '%1' to '%2', rescanning",
                    $cur_base, $self->get_conf('base')
                ),
                0
            );
            $self->init( @_, rescan => 1 );
        }

        $obj->_clean_up_paths;

        {
            my $lib = $self->get_conf('lib');
            my %inc = map { $_ => $_ } @INC;
            for my $l (@$lib) {
                push @INC, $l unless $inc{$l};
            }
            $self->_lib( \@INC );
        }

        return 1;
    }
}

sub can_save {
    my $self = shift;
    my $file = shift || CONFIG_USER_FILE->();

    return 1 unless -e $file;

    chmod 0644, $file;
    return ( -w $file );
}


sub _config_pm_to_file {
    my $self = shift;
    my $pm   = shift or return;
    my $dir  = shift || CONFIG_USER_LIB_DIR->();

    my $file;
    if ( $pm eq CONFIG_USER ) {
        $file = CONFIG_USER_FILE->();

    }
    elsif ( $pm eq CONFIG_SYSTEM ) {
        $file = CONFIG_SYSTEM_FILE->();

    }
    else {
        my $cfg_pkg = CONFIG . '::';
        unless ( $pm =~ /^$cfg_pkg/ ) {
            error(
                loc(
                    "WARNING: Your config package '%1' is not in the '%2' "
                      . "namespace and will not be automatically detected by %3",
                    $pm,
                    $cfg_pkg,
                    'CPANPLUS'
                )
            );
        }

        $file = File::Spec->catfile( $dir, split( '::', $pm ) ) . '.pm';
    }

    return $file;
}

sub save {
    my $self    = shift;
    my $pm      = shift || CONFIG_USER;
    my $savedir = shift || '';

    my $file = $self->_config_pm_to_file( $pm, $savedir ) or return;
    my $dir = dirname($file);

    unless ( -d $dir ) {
        $self->_mkdir( dir => $dir )
          or (
            error(
                loc( "Can not create directory '%1' to save config to", $dir )
            ),
            return
          );
    }
    return unless $self->can_save($file);

    my @acc = sort grep { $_ !~ /^_/ } $self->conf->ls_accessors;

    use Data::Dumper;

    my @lines;
    for my $acc (@acc) {

        push @lines, "### $acc section", $/;

        for my $key ( $self->conf->$acc->ls_accessors ) {
            my $val = Dumper( $self->conf->$acc->$key );

            $val =~ s/\$VAR1\s+=\s+//;
            $val =~ s/;\n//;

            push @lines, '$' . "conf->set_${acc}( $key => $val );", $/;
        }
        push @lines, $/, $/;

    }

    my $str = join '', map { "    $_" } @lines;

    my $is   = '=';
    my $time = gmtime;

    my $msg = <<_END_OF_CONFIG_;
###############################################
###
###  Configuration structure for $pm
###
###############################################

#last changed: $time GMT

### minimal pod, so you can find it with perldoc -l, etc
${is}pod

${is}head1 NAME

$pm

${is}head1 DESCRIPTION

This is a CPANPLUS configuration file. Editing this
config changes the way CPANPLUS will behave

${is}cut

package $pm;

use strict;

sub setup {
    my \$conf = shift;

$str

    return 1;
}

1;

_END_OF_CONFIG_

    $self->_move( file => $file, to => "$file~" ) if -f $file;

    my $fh = new FileHandle;
    $fh->open(">$file")
      or ( error( loc( "Could not open '%1' for writing: %2", $file, $! ) ),
        return );

    $fh->print($msg);
    $fh->close;

    return $file;
}


sub options {
    my $self = shift;
    my $conf = $self->conf;
    my %hash = @_;

    my $type;
    my $tmpl = {
        type => {
            required    => 1,
            default     => '',
            strict_type => 1,
            store       => \$type
        },
    };

    check( $tmpl, \%hash ) or return;

    my %seen;
    return sort grep { !$seen{$_}++ }
      map { $_->$type->ls_accessors if $_->can($type) } $self->conf;
    return;
}


sub AUTOLOAD {
    my $self = shift;
    my $conf = $self->conf;

    my $name = $AUTOLOAD;
    $name =~ s/.+:://;

    my ( $private, $action, $field ) =
      $name =~ m/^(_)?((?:[gs]et|add))_([a-z]+)$/;

    my $type = '';
    $type .= '_' if $private;
    $type .= $field if $field;

    unless ( $conf->can($type) ) {
        error( loc( "Invalid method type: '%1'", $name ) );
        return;
    }

    unless ( scalar @_ ) {
        error( loc("No arguments provided!") );
        return;
    }

    if ( $action eq 'get' ) {
        for my $key (@_) {
            my @list = ();

            if ( $conf->can($type) and $conf->$type->can($key) ) {
                push @list, $conf->$type->$key;

            }
            elsif ( $type eq '_build' and $key eq 'base' ) {
                return $self->get_conf($key);

            }
            else {
                error( loc( q[No such key '%1' in field '%2'], $key, $type ) );
                return;
            }

            return wantarray ? @list : $list[0];
        }

    }
    elsif ( $action eq 'set' ) {
        my %args = @_;

        while ( my ( $key, $val ) = each %args ) {

            if ( $conf->can($type) and $conf->$type->can($key) ) {
                $conf->$type->$key($val);

            }
            else {
                error( loc( q[No such key '%1' in field '%2'], $key, $type ) );
                return;
            }
        }

        return 1;

    }
    elsif ( $action eq 'add' ) {
        my %args = @_;

        while ( my ( $key, $val ) = each %args ) {

            if ( $conf->$type->can($key) ) {
                error(
                    loc(
                        q[Key '%1' already exists for field '%2'], $key,
                        $type
                    )
                );
                return;
            }
            else {
                $conf->$type->mk_accessors($key);
                $conf->$type->$key($val);
            }
        }
        return 1;

    }
    else {

        error( loc( q[Unknown action '%1'], $action ) );
        return;
    }
}

sub DESTROY { 1 }

1;


