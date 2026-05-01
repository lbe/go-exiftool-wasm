package CPANPLUS::Dist;

use strict;

use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;

use Cwd ();
use Object::Accessor;
use Parse::CPAN::Meta;

use IPC::Cmd qw[run];
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load check_install];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

use base 'Object::Accessor';

local $Params::Check::VERBOSE = 1;



sub new {
    my $self  = shift;
    my $class = ref $self || $self;
    my %hash  = @_;

    my ( $mod, $format );
    my $tmpl = {
        module => { required => 1, allow => IS_MODOBJ, store => \$mod },
        format => {
            default => $class,
            store   => \$format,
            allow   => [ __PACKAGE__->dist_types ],
        },
    };
    check( $tmpl, \%hash ) or return;

    unless ( can_load( modules => { $format => '0.0' }, verbose => 1 ) ) {
        error(
            loc(
                "'%1' not found -- you need '%2' version '%3' or higher "
                  . "to detect plugins",
                $format,
                'Module::Pluggable',
                '2.4'
            )
        );
        return;
    }

    my $obj = $format->SUPER::new;

    $obj->mk_accessors(qw[parent status]);

    $obj->parent($mod);

    {
        my $acc = Object::Accessor->new;
        $obj->status($acc);

        $acc->mk_accessors(
            qw[prepared created installed uninstalled
              distdir dist]
        );
    }

    my $conf = $mod->parent->configure_object();

    if ( $conf->_get_build('sanity_check') and not $obj->format_available ) {
        error( loc( "Format '%1' is not available", $format ) );
        return;
    }

    unless ( $obj->init ) {
        error(
            loc(
                "Dist initialization of '%1' failed for '%2'", $format,
                $mod->module
            )
        );
        return;
    }

    return $obj;
}


{
    my $Loaded;
    my @Dists  = (INSTALLER_MM);
    my @Ignore = ();

    sub _add_dist_types { my $self = shift; push @Dists, @_ }

    sub _ignore_dist_types { my $self = shift; push @Ignore, @_ }
    sub _reset_dist_ignore { @Ignore = () }

    sub dist_types {

        if (
            !$Loaded++
            and check_install(
                module  => 'Module::Pluggable',
                version => '2.4'
            )
          )
        {
            require Module::Pluggable;

            my $only_re = __PACKAGE__ . '::\w+$';
            my %except = map { $_ => 1 } INSTALLER_SAMPLE, INSTALLER_BASE;

            Module::Pluggable->import(
                sub_name    => '_dist_types',
                search_path => __PACKAGE__,
                only        => qr/$only_re/,
                require     => 1,
                except      => [ keys %except ]
            );
            my %ignore = map { $_ => $_ } @Ignore;

            push @Dists,
              grep { not $ignore{$_} and not $except{$_} }
              __PACKAGE__->_dist_types;
        }

        return @Dists;
    }


    sub rescan_dist_types {
        my $dist = shift;
        $Loaded = 0;
        return $dist->dist_types;
    }
}


sub has_dist_type {
    my $dist = shift;
    my $type = shift or return;

    return scalar grep { $_ eq $type } CPANPLUS::Dist->dist_types;
}


sub prereq_satisfied {
    my $dist = shift;
    my $cb   = $dist->parent->parent;
    my %hash = @_;

    my ( $mod, $ver );
    my $tmpl = {
        version => { required => 1, store => \$ver },
        modobj  => { required => 1, store => \$mod, allow => IS_MODOBJ },
    };

    check( $tmpl, \%hash ) or return;

    return 1 if $mod->is_uptodate( version => $ver );

    if ( $cb->_vcmp( $ver, $mod->version ) > 0 ) {

        error(
            loc(
                "This distribution depends on %1, but the latest version"
                  . " of %2 on CPAN (%3) doesn't satisfy the specific version"
                  . " dependency (%4). You may have to resolve this dependency "
                  . "manually.",
                $mod->module, $mod->module, $mod->version, $ver
            )
        );

    }

    return;
}


sub find_configure_requires {
    my $self = shift;
    my $mod  = $self->parent;
    my %hash = @_;

    my ($meta);
    my $href = {};

    my $tmpl = { file => { store => \$meta }, };

    check( $tmpl, \%hash ) or return;

    my $meth = 'configure_requires';

    {

        my @args = ( defaults => $mod->status->$meth || {}, );

        my @possibles = do {
            defined $mod->status->extract
              ? (
                META_JSON->( $mod->status->extract ),
                META_YML->( $mod->status->extract )
              )
              : ();
        };

        unshift @possibles, $meta if $meta;

      META: foreach my $mfile ( grep { -e } @possibles ) {
            push @args, ( file => $mfile );
            if ( $mfile =~ /\.json/ ) {
                $href =
                  $self->_prereqs_from_meta_json( @args,
                    keys => ['configure'] );
            }
            else {
                $href =
                  $self->_prereqs_from_meta_file( @args, keys => [$meth] );
            }
            last META;
        }

    }

    $mod->status->$meth($href);

    return {%$href};
}

sub find_mymeta_requires {
    my $self = shift;
    my $mod  = $self->parent;
    my %hash = @_;

    my ($meta);
    my $href = {};

    my $tmpl = { file => { store => \$meta }, };

    check( $tmpl, \%hash ) or return;

    my $meth = 'prereqs';

    {

        my @args = ( defaults => $mod->status->$meth || {}, );

        my @possibles = do {
            defined $mod->status->extract
              ? (
                MYMETA_JSON->( $mod->status->extract ),
                MYMETA_YML->( $mod->status->extract )
              )
              : ();
        };

        unshift @possibles, $meta if $meta;

      META: foreach my $mfile ( grep { -e } @possibles ) {
            push @args, ( file => $mfile );
            if ( $mfile =~ /\.json/ ) {
                $href =
                  $self->_prereqs_from_meta_json( @args,
                    keys => [qw|build test runtime|] );
            }
            else {
                $href =
                  $self->_prereqs_from_meta_file( @args,
                    keys => [qw|build_requires requires|] );
            }
            last META;
        }

    }

    $mod->status->$meth($href);

    return {%$href};
}

sub _prereqs_from_meta_file {
    my $self = shift;
    my $mod  = $self->parent;
    my %hash = @_;

    my ( $meta, $defaults, $keys );
    my $tmpl = { file => {
            default => do {
                defined $mod->status->extract
                  ? META_YML->( $mod->status->extract )
                  : '';
            },
            store => \$meta,
        },
        defaults => {
            required    => 1,
            default     => {},
            strict_type => 1,
            store       => \$defaults
        },
        keys => {
            required    => 1,
            default     => [],
            strict_type => 1,
            store       => \$keys
        },
    };

    check( $tmpl, \%hash ) or return;

    if ( -e $meta ) {

        local $ENV{PERL_JSON_BACKEND};

        my ($doc) = eval { Parse::CPAN::Meta::LoadFile($meta) };

        unless ($doc) {
            error( loc( "Could not read %1: '%2'", $meta, $@ ) );
            return $defaults;
        }

        for my $key (@$keys) {
            $defaults = { %$defaults, %{ $doc->{$key} }, } if $doc->{$key};
        }
    }

    return \%{$defaults};
}

sub _prereqs_from_meta_json {
    my $self = shift;
    my $mod  = $self->parent;
    my %hash = @_;

    my ( $meta, $defaults, $keys );
    my $tmpl = { file => {
            default => do {
                defined $mod->status->extract
                  ? META_JSON->( $mod->status->extract )
                  : '';
            },
            store => \$meta,
        },
        defaults => {
            required    => 1,
            default     => {},
            strict_type => 1,
            store       => \$defaults
        },
        keys => {
            required    => 1,
            default     => [],
            strict_type => 1,
            store       => \$keys
        },
    };

    check( $tmpl, \%hash ) or return;

    if ( -e $meta ) {

        local $ENV{PERL_JSON_BACKEND};

        my ($doc) = eval { Parse::CPAN::Meta->load_file($meta) };

        unless ($doc) {
            error( loc( "Could not read %1: '%2'", $meta, $@ ) );
            return $defaults;
        }

        my $prereqs = $doc->{prereqs} || {};
        for my $key (@$keys) {
            $defaults = { %$defaults, %{ $prereqs->{$key}->{requires} }, }
              if $prereqs->{$key}->{requires};
        }
    }

    return \%{$defaults};
}


sub _resolve_prereqs {
    my $dist = shift;
    my $self = $dist->parent;
    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my ( $prereqs, $format, $verbose, $target, $force, $prereq_build,
        $tolerant );
    my $tmpl = {
        format => {
            required => 1,
            store    => \$format,
            allow    => [ '', __PACKAGE__->dist_types ],
        },
        prereqs => {
            required    => 1,
            default     => {},
            strict_type => 1,
            store       => \$prereqs
        },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        force => {
            default => $conf->get_conf('force'),
            store   => \$force
        },
        target => {
            default => '',
            store   => \$target,
            allow   => [ '', qw[create ignore install] ]
        },
        prereq_build => { default => 0, store => \$prereq_build },
        tolerant     => {
            default => $conf->get_conf('allow_unknown_prereqs'),
            store   => \$tolerant
        },
    };

    check( $tmpl, \%hash ) or return;

    return 1 unless keys %$prereqs;

    my $original_wd = Cwd::cwd;

    $target ||= {
        PREREQ_ASK,    TARGET_INSTALL, PREREQ_BUILD,   TARGET_CREATE,
        PREREQ_IGNORE, TARGET_IGNORE,  PREREQ_INSTALL, TARGET_INSTALL,
      }->{ $conf->get_conf('prereqs') }
      || '';

    my @sorted_prereqs;

    if ( $self->module =~ /^Bundle(::|-)CPANPLUS(::|-)Dependencies/ ) {
        my ( @first, @last );
        for my $mod ( sort keys %$prereqs ) {
            $mod =~ /CPANPLUS/
              ? push @last, $mod
              : push @first, $mod;
        }
        @sorted_prereqs = ( @first, @last );
    }
    else {
        @sorted_prereqs = sort keys %$prereqs;
    }

    my @install_me;

    my $flag;

    for my $mod (@sorted_prereqs) {
        ( my $version = $prereqs->{$mod} ) =~ s#[^0-9\._]+##g;

        if ( $mod eq PERL_CORE ) {

            my $ok = run( command => "$^X -M$version -e1", verbose => 0 );

            unless ($ok) {
                error(
                    loc(
                        "Module '%1' needs perl version '%2', but you "
                          . "only have version '%3' -- can not proceed",
                        $self->module, $version,
                        $cb->_perl_version( perl => $^X )
                    )
                );
                return;
            }

            next;
        }

        my $modobj = $cb->module_tree($mod);

        unless ($modobj) {
            my $sub =
              CPANPLUS::Module->can('module_is_supplied_with_perl_core');
            my $core = $sub->($mod);
            unless ( defined $core ) {
                error( loc( "No such module '%1' found on CPAN", $mod ) );
                $flag++ unless $tolerant;
                next;
            }
            if ( $cb->_vcmp( $version, $core ) > 0 ) {
                error(
                    loc(
                        "Version of core module '%1' ('%2') is too low for "
                          . "'%3' (needs '%4') -- carrying on but this may be a problem",
                        $mod, $core, $self->module, $version
                    )
                );
            }
            next;
        }

        if (
            !$dist->prereq_satisfied( modobj => $modobj, version => $version ) )
        {
            msg(
                loc(
                    "Module '%1' requires '%2' version '%3' to be installed ",
                    $self->module, $modobj->module, $version
                ),
                $verbose
            );

            push @install_me, [ $modobj, $version ];

        }
        elsif ( INSTALL_VIA_PACKAGE_MANAGER->($format)
            and !$modobj->package_is_perl_core
            and ( $target ne TARGET_IGNORE ) )
        {
            msg(
                loc(
                    "Module '%1' depends on '%2', may need to build a '%3' "
                      . "package for it as well",
                    $self->module, $modobj->module, $format
                )
            );
            push @install_me, [ $modobj, $version ];
        }
    }

    if ( $target eq TARGET_IGNORE ) {

        if (@install_me) {
            msg( loc("Ignoring prereqs, this may mean your install will fail"),
                $verbose );
            msg(
                loc( "'%1' listed the following dependencies:", $self->module ),
                $verbose
            );

            for my $aref (@install_me) {
                my ( $mod, $version ) = @$aref;

                my $str = sprintf "\t%-35s %8s\n", $mod->module, $version;
                msg( $str, $verbose );
            }

            return;

        }
        else {
            return 1;
        }
    }

    for my $aref (@install_me) {
        my ( $modobj, $version ) = @$aref;

        next
          if ( !$force and !$prereq_build )
          && $dist->prereq_satisfied( modobj => $modobj, version => $version );

        if (
            (
                $conf->get_conf('prereqs') == PREREQ_ASK
                and
                not $cb->_callbacks->install_prerequisite->( $self, $modobj )
            )
          )
        {
            msg(
                loc(
                    "Will not install prerequisite '%1' -- Note "
                      . "that the overall install may fail due to this",
                    $modobj->module
                ),
                $verbose
            );
            next;
        }

        if ( defined $modobj->status->installed
            && !$modobj->status->installed )
        {
            error(
                loc(
                    "Prerequisite '%1' failed to install before in "
                      . "this session",
                    $modobj->module
                )
            );
            $flag++;
            last;
        }

        if ( $modobj->package_is_perl_core ) {
            error(
                loc(
                    "Prerequisite '%1' is perl-core (%2) -- not "
                      . "installing that. -- Note that the overall "
                      . "install may fail due to this.",
                    $modobj->module,
                    $modobj->package
                )
            );
            next;
        }

        my $pending = $cb->_status->pending_prereqs || {};

        if ( $pending->{ $modobj->module } ) {
            error(
                loc(
                    "Recursive dependency detected (%1) -- skipping",
                    $modobj->module
                )
            );
            next;
        }

        $pending->{ $modobj->module } = $modobj;
        $cb->_status->pending_prereqs($pending);

        my $pa = $dist->status->_prepare_args || {};
        my $ca = $dist->status->_create_args  || {};
        my $ia = $dist->status->_install_args || {};

        unless (
            $modobj->install(
                %$pa, %$ca, %$ia,
                force   => $force,
                verbose => $verbose,
                format  => $format,
                target  => $target
            )
          )
        {
            error(
                loc(
                    "Failed to install '%1' as prerequisite " . "for '%2'",
                    $modobj->module, $self->module
                )
            );
            $flag++;
        }

        $pending->{ $modobj->module } = 0;
        $cb->_status->pending_prereqs($pending);

        last if $flag;

        if ( $target ne TARGET_INSTALL ) {
            my $dir = $modobj->status->extract
              or error(
                loc(
                    "No extraction dir for '%1' found " . "-- weird",
                    $modobj->module
                )
              );

            $modobj->add_to_includepath();

            next;
        }
    }

    keys %$prereqs;

    $cb->_chdir( dir => $original_wd );

    return 1 unless $flag;
    return;
}

1;

