package CPANPLUS::Module;

use strict;
use vars qw[@ISA];

use CPANPLUS::Dist;
use CPANPLUS::Error;
use CPANPLUS::Module::Signature;
use CPANPLUS::Module::Checksums;
use CPANPLUS::Internals::Constants;

use FileHandle;

use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';
use IPC::Cmd qw[can_run run];
use File::Find qw[find];
use Params::Check qw[check];
use File::Basename qw[dirname];
use Module::Load::Conditional qw[can_load check_install];

$Params::Check::VERBOSE = 1;

@ISA = qw[ CPANPLUS::Module::Signature CPANPLUS::Module::Checksums];


my $tmpl = {
    module => { default => '', required => 1 }, version => { default => '0.0' }
    , path => { default => '', required => 1 },   comment => { default => '' }
    , package => { default => '', required => 1 },  description =>
      { default => '' },  dslip => { default => EMPTY_DSLIP }, _id =>
      { required => 1 },  _status => { no_override => 1 }, author => {
        default  => '',
        required => 1,
        allow    => IS_AUTHOBJ
      }, mtime => { default => '' },
};

{
    my %rename = ( dslip => '_dslip' );

    for my $key ( keys %$tmpl ) {
        no strict 'refs';

        my $sub = $rename{$key} || $key;

        *{ __PACKAGE__ . "::$sub" } = sub {
            $_[0]->{$key} = $_[1] if @_ > 1;
            return $_[0]->{$key};
          }
    }
}


sub accessors { return ( 'name', keys %$tmpl ) }


sub dslip {
    my $self = shift;

    return $self->_dslip if $self->_dslip ne EMPTY_DSLIP;

    for my $mod ( $self->contains ) {
        return $mod->_dslip if $mod->_dslip ne EMPTY_DSLIP;
    }

    return EMPTY_DSLIP;
}


*name = *module;

sub parent {
    my $self = shift;
    my $obj  = CPANPLUS::Internals->_retrieve_id( $self->_id );

    return $obj;
}


sub new {
    my ( $class, %hash ) = @_;

    local $Params::Check::SANITY_CHECK_TEMPLATE = 0;

    my $object = check( $tmpl, \%hash ) or return;

    bless $object, $class;

    return $object;
}

sub status {
    my $self = shift;
    return $self->_status if $self->_status;

    my $acc = Object::Accessor->new;
    $acc->mk_accessors(
        qw[ installer_type dist_cpan dist prereqs
          signature extract fetch readme uninstall
          created installed prepared checksums files
          checksum_ok checksum_value _fetch_from
          configure_requires
          ]
    );

    $acc->mk_aliases( requires => 'prereqs' );

    $self->_status($acc);

    return $self->_status;
}

sub _flush {
    my $self = shift;
    $self->status->mk_flush;
    return 1;
}


{ my %map = (
        name      => 0,
        version   => 1,
        extension => 2,
    );

    while ( my ( $type, $index ) = each %map ) {
        my $name = 'package_' . $type;

        no strict 'refs';
        *$name = sub {
            my $self = shift;
            my $val  = shift || $self->package;
            my @res  = $self->parent->_split_package_string( package => $val );

            return $res[$index] if @res;
            return;
        };
    }

    sub package_is_perl_core {
        my $self = shift;
        my $cb   = $self->parent;

        return 1 if $self->package_name eq PERL_CORE;

        my $core = $self->module_is_supplied_with_perl_core;
        if ( defined $core ) {
            return
              if $cb->_vcmp( $self->version, $self->installed_version ) > 0;

            return if $cb->_vcmp( $self->version, $core ) >= 0;

            return 1;
        }

        return;
    }

    sub module_is_supplied_with_perl_core {
        my $self = shift;
        my $ver = shift || $];

        my $name = ref $self ? $self->module : $self;

        require Module::CoreList;

        my $core;

        if ( exists $Module::CoreList::version{ 0 + $ver }->{$name} ) {
            $core = $Module::CoreList::version{ 0 + $ver }->{$name};
            $core = 0 unless $core;
        }
        return $core;
    }

    sub is_bundle {
        my $self = shift;

        return 1 if $self->module =~ /^bundle(?:-|::)/i;

        return 1 if $self->is_autobundle;

        return;
    }

    sub is_autobundle {
        my $self   = shift;
        my $conf   = $self->parent->configure_object;
        my $prefix = $conf->_get_build('autobundle_prefix');

        return 1 if $self->module eq $prefix;
        return;
    }

    sub is_third_party {
        my $self = shift;

        return unless can_load( modules => { 'Module::ThirdParty' => 0 } );

        return Module::ThirdParty::is_3rd_party( $self->name );
    }

    sub third_party_information {
        my $self = shift;

        return unless $self->is_third_party;

        return Module::ThirdParty::module_information( $self->name );
    }
}


{ my @acc = grep !/status/, __PACKAGE__->accessors();

    sub clone {
        my $self = shift;

        my %data = map { $_ => $self->$_ } @acc;

        my $obj = CPANPLUS::Module::Fake->new(%data);

        return $obj;
    }
}


sub fetch {
    my $self = shift;
    my $cb   = $self->parent;

    my %args = ( module => $self );

    $args{fetch_from} = $self->status->_fetch_from
      if $self->status->_fetch_from;

    my $where = $cb->_fetch( @_, %args ) or return;

    if (   !$self->status->_fetch_from
        and $cb->configure_object->get_conf('md5')
        and $self->package ne CHECKSUMS )
    {
        unless ( $self->_validate_checksum ) {
            error(
                loc(
                    "Checksum error for '%1' -- will not trust package",
                    $self->package
                )
            );
            return;
        }
    }

    return $where;
}


sub extract {
    my $self = shift;
    my $cb   = $self->parent;

    unless ( $self->status->fetch ) {
        error(
            loc(
                "You have not fetched '%1' yet -- cannot extract",
                $self->module
            )
        );
        return;
    }

    if ( $self->is_autobundle ) {

        $self->get_installer_type;

        return $self->status->extract( dirname( $self->status->fetch ) );
    }

    return $cb->_extract( @_, module => $self );
}


sub get_installer_type {
    my $self = shift;
    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my ( $prefer_makefile, $verbose );
    my $tmpl = {
        prefer_makefile => {
            default => $conf->get_conf('prefer_makefile'),
            store   => \$prefer_makefile,
            allow   => BOOLEANS
        },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
    };

    check( $tmpl, \%hash ) or return;

    my $type;

    if ( $self->is_autobundle ) {
        $type = INSTALLER_AUTOBUNDLE;

    }
    else {
        my $extract = $self->status->extract();
        unless ($extract) {
            error(
                loc(
"Cannot determine installer type of unextracted module '%1'",
                    $self->module
                )
            );
            return;
        }

        my $found_build    = -e BUILD_PL->($extract);
        my $found_makefile = -e MAKEFILE_PL->($extract);

        $type = INSTALLER_BUILD if !$prefer_makefile && $found_build;
        $type = INSTALLER_BUILD if $found_build      && !$found_makefile;
        $type = INSTALLER_MM    if $prefer_makefile  && $found_makefile;
        $type = INSTALLER_MM    if $found_makefile   && !$found_build;
        $type = INSTALLER_MM if $self->package =~ m{^Module-Build-\d};

    }

    if (
            $type
        and $type eq INSTALLER_BUILD
        and (  not CPANPLUS::Dist->has_dist_type(INSTALLER_BUILD)
            or not $cb->module_tree(INSTALLER_BUILD)
            ->is_uptodate( version => '0.60' ) )
      )
    {

        my $href = $self->status->configure_requires || {};
        my $deps = { INSTALLER_BUILD, '0.60', %$href };

        $self->status->configure_requires($deps);

        msg(
            loc(
                "This module requires '%1' and '%2' to be installed first. "
                  . "Adding these modules to your prerequisites list",
                'Module::Build',
                INSTALLER_BUILD
            ),
            $verbose
        );

    }
    elsif ( !$type ) {
        error(
            loc(
                "Unable to find '%1' or '%2' for '%3'; "
                  . "Will default to '%4' but might be unable "
                  . "to install!",
                BUILD_PL->(),
                MAKEFILE_PL->(),
                $self->module,
                INSTALLER_MM
            )
        );
        $type = INSTALLER_MM;
    }

    return $self->status->installer_type($type) if $type;
    return;
}


sub dist {
    my $self = shift;
    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    $self->get_installer_type unless $self->status->installer_type;

    my ( $type, $args, $target );
    my $tmpl = {
        format => {
            default => $conf->get_conf('dist_type')
              || $self->status->installer_type,
            store => \$type
        },
        target => { default => TARGET_CREATE, store => \$target },
        args   => { default => {},            store => \$args },
    };

    check( $tmpl, \%hash ) or return;

    unless ( CPANPLUS::Dist->has_dist_type($type) ) {

        if ( $type eq INSTALLER_BUILD ) {
            msg( loc( "Bootstrapping installer '%1'", $type ) );

            $cb->module_tree($type)->install( target => $target, %$args )
              or do {
                error(
                    loc(
                        "Could not bootstrap installer '%1' -- "
                          . "can not continue",
                        $type
                    )
                );
                return;
              };

            CPANPLUS::Dist->rescan_dist_types;

            unless ( CPANPLUS::Dist->has_dist_type($type) ) {
                error(
                    loc(
                        "Newly installed installer type '%1' should be "
                          . "available, but is not! -- aborting",
                        $type
                    )
                );
                return;
            }
            else {
                msg( loc( "Installer '%1' successfully bootstrapped", $type ) );
            }

        }
        else {
            error(
                loc(
                    "Installer type '%1' not found. Please verify your "
                      . "installation -- aborting",
                    $type
                )
            );
            return;
        }
    }

    my ( $dist, $dist_cpan );

    unless ( $dist = $self->status->dist ) {
        $dist = $type->new( module => $self ) or return;
        $self->status->dist($dist);
    }

    unless ( $dist_cpan = $self->status->dist_cpan ) {

        $dist_cpan =
            $type eq $self->status->installer_type
          ? $self->status->dist
          : $self->status->installer_type->new( module => $self );

        $self->status->dist_cpan($dist_cpan);
    }

  DIST: {
        last DIST if $target eq TARGET_INIT;

        $dist->prepare(%$args) or return;
        $self->status->prepared(1);

        last DIST if $target eq TARGET_PREPARE;

        $dist->create(%$args) or return;
        $self->status->created(1);
    }

    return $dist;
}


sub prepare {
    my $self = shift;
    return $self->install( @_, target => TARGET_PREPARE );
}


sub create {
    my $self = shift;
    return $self->install( @_, target => TARGET_CREATE );
}


sub test {
    my $self = shift;
    return $self->install( @_, target => TARGET_CREATE, skiptest => 0 );
}


sub install {
    my $self = shift;
    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my $args;
    my $target;
    my $format;
    { local $Params::Check::NO_DUPLICATES = 1;
        local $Params::Check::ALLOW_UNKNOWN = 1;

        my $tmpl = {
            target => {
                default => TARGET_INSTALL,
                store   => \$target,
                allow   => [
                    TARGET_PREPARE, TARGET_CREATE, TARGET_INSTALL, TARGET_INIT
                ]
            },
            force   => { default => $conf->get_conf('force'), },
            verbose => { default => $conf->get_conf('verbose'), },
            format  => {
                default => $conf->get_conf('dist_type'),
                store   => \$format
            },
        };

        $args = check( $tmpl, \%hash ) or return;
    }

    $args->{'prereq_target'} ||= TARGET_CREATE if $target ne TARGET_INSTALL;

    if (    $target eq TARGET_INSTALL
        and !$args->{'force'}
        and !$self->package_is_perl_core()
        and ( $self->status->installed() or $self->is_uptodate )
        and !INSTALL_VIA_PACKAGE_MANAGER->($format) )
    {
        msg(
            loc(
                "Module '%1' already up to date, won't install without force",
                $self->module
            ),
            $args->{'verbose'}
        );
        return $self->status->installed(1);
    }

    if ( $self->package_is_perl_core() ) {
        if ( $self->installed_version > $self->version ) {
            error(
                loc(
                    "The core Perl %1 module '%2' (%3) is more "
                      . "recent than the latest release on CPAN (%4). "
                      . "Aborting install.",
                    $],                       $self->module,
                    $self->installed_version, $self->version
                )
            );
        }
        elsif ( $self->installed_version == $self->version ) {
            error(
                loc(
                    "The core Perl %1 module '%2' (%3) can only "
                      . "be installed by Perl itself. "
                      . "Aborting install.",
                    $], $self->module, $self->installed_version
                )
            );
        }
        else {
            error(
                loc(
                    "The core Perl %1 module '%2' can only be "
                      . "upgraded from %3 to %4 by Perl itself (%5). "
                      . "Aborting install.",
                    $],                       $self->module,
                    $self->installed_version, $self->version,
                    $self->package
                )
            );
        }
        return;

    }
    elsif ( $self->is_third_party ) {
        my $info = $self->third_party_information;
        error(
            loc(
                "%1 is a known third-party module.\n\n"
                  . "As it isn't available on the CPAN, CPANPLUS can't install "
                  . "it automatically. Therefore you need to install it manually "
                  . "before proceeding.\n\n"
                  . "%2 is part of %3, published by %4, and should be available "
                  . "for download at the following address:\n\t%5",
                $self->name,     $self->name, $info->{name},
                $info->{author}, $info->{url}
            )
        );

        return;
    }

    unless ( $self->status->fetch ) {
        my $params;
        for (qw[prefer_bin fetchdir]) {
            $params->{$_} = $args->{$_} if exists $args->{$_};
        }
        for (qw[force verbose]) {
            $params->{$_} = $args->{$_} if defined $args->{$_};
        }
        $self->fetch(%$params) or return;
    }

    unless ( $self->status->extract ) {
        my $params;
        for (qw[prefer_bin extractdir]) {
            $params->{$_} = $args->{$_} if exists $args->{$_};
        }
        for (qw[force verbose]) {
            $params->{$_} = $args->{$_} if defined $args->{$_};
        }
        $self->extract(%$params) or return;
    }

    $args->{'prereq_format'} = $format if $format;
    $format ||= $self->status->installer_type;

    unless ($format) {
        error(
            loc(
                "Don't know what installer to use; "
                  . "Couldn't find either '%1' or '%2' in the extraction "
                  . "directory '%3' -- will be unable to install",
                BUILD_PL->(),
                MAKEFILE_PL->(),
                $self->status->extract
            )
        );

        $self->status->installed(0);
        return;
    }

    if ( $conf->get_conf('signature') ) {
        unless ( $self->check_signature( verbose => $args->{verbose} ) ) {
            error(
                loc(
                    "Signature check failed for module '%1' "
                      . "-- Not trusting this module, aborting install",
                    $self->module
                )
            );
            $self->status->signature(0);

            if ( $conf->get_conf('cpantest') ) {
                $cb->_send_report(
                    module  => $self,
                    failed  => 1,
                    buffer  => CPANPLUS::Error->stack_as_string,
                    verbose => $args->{verbose},
                    force   => $args->{force},
                  )
                  or error(
                    loc( "Failed to send test report for '%1'", $self->module )
                  );
            }

            return;

        }
        else {
            $self->status->signature(1);
        }
    }

    if ( $self->is_bundle ) {
        my @prereqs = $self->bundle_modules();
        unless (@prereqs) {
            error(
                loc(
                    "Bundle '%1' does not specify any modules to install",
                    $self->module
                )
            );

        }
    }

    my $dist = $self->dist(
        format => $format,
        target => $target,
        args   => $args
    );
    unless ($dist) {
        error(
            loc(
                "Unable to create a new distribution object for '%1' "
                  . "-- cannot continue",
                $self->module
            )
        );
        return;
    }

    return 1 if $target ne TARGET_INSTALL;

    my $ok = $dist->install(%$args) ? 1 : 0;

    $self->status->installed($ok);

    return 1 if $ok;
    return;
}


sub bundle_modules {
    my $self = shift;
    my $cb   = $self->parent;

    unless ( $self->is_bundle ) {
        error( loc( "'%1' is not a bundle", $self->module ) );
        return;
    }

    my @files;

    if ( $self->is_autobundle ) {
        my $where;
        unless ( $where = $self->status->fetch ) {
            error(
                loc( "Don't know where '%1' was fetched to", $self->package ) );
            return;
        }

        push @files, $where

    }
    else {
        my $dir;
        unless ( $dir = $self->status->extract ) {
            error(
                loc( "Don't know where '%1' was extracted to", $self->module )
            );
            return;
        }

        find(
            {
                wanted =>
                  sub { push @files, File::Spec->rel2abs($_) if /\.pm/i },
                no_chdir => 1,
            },
            $dir
        );
    }

    my $prereqs = {};
    my @list;
    my $seen = {};
    for my $file (@files) {
        my $fh = FileHandle->new($file)
          or ( error( loc( "Could not open '%1' for reading: %2", $file, $! ) ),
            next );

        my $flag;
        while ( local $_ = <$fh> ) {
            last if $flag && m|^=head|i;

            $flag = 1 if m|^=head1 CONTENTS|i;

            if ( $flag && /^(?!=)(\S+)\s*(\S+)?/ ) {
                my $module = $1;
                my $version = $cb->_version_to_number( version => $2 );

                my $obj = $cb->module_tree($module);

                unless ($obj) {
                    error( loc( "Cannot find bundled module '%1'", $module ),
                        loc("-- it does not seem to exist") );
                    next;
                }

                unless ( $seen->{ $obj->module }++ ) {
                    push @list, $obj;
                    $prereqs->{$module} =
                      $cb->_version_to_number( version => $version );
                }
            }
        }
    }

    $self->status->prereqs($prereqs);

    return @list;
}


sub readme {
    my $self = shift;
    my $conf = $self->parent->configure_object;

    return $self->status->readme() if $self->status->readme();

    return unless can_load(
        modules => { FileHandle => '0.0' },
        verbose => 1,
    );

    my $obj = $self->clone or return;

    my $pkg = README->($obj);
    $obj->package($pkg);

    my $file;
    {

        my $tmp = $conf->get_conf('md5');
        $conf->set_conf( md5 => 0 );

        $file = $obj->fetch;

        $conf->set_conf( md5 => $tmp );

        return unless $file;
    }

    my $fh = new FileHandle;
    unless ( $fh->open($file) ) {
        error( loc( "Could not open file '%1': %2", $file, $! ) );
        return;
    }

    my $in = do { local $/; <$fh> };
    $fh->close;

    return $self->status->readme($in);
}


{
    my $map = { installed_version => [ 'version', 0 ],
        installed_file => [ 'file',     '' ],
        installed_dir  => [ 'dir',      '' ],
        is_uptodate    => [ 'uptodate', 0 ], };

    while ( my ( $method, $aref ) = each %$map ) {
        my ( $key, $alt_rv ) = @$aref;

        no strict 'refs';
        *$method = sub {

            my $self = shift;

            local $Module::Load::Conditional::CHECK_INC_HASH = 0;
            local $Module::Load::Conditional::DEPRECATED     = 1;
            my $href = check_install(
                module  => $self->module,
                version => $self->version,
                @_,
            );

            return $alt_rv if defined $href->{dir} && ref $href->{dir};

            return $href->{$key} || $alt_rv;
          }
    }
}


sub details {
    my $self = shift;
    my $conf = $self->parent->configure_object();
    my $cb   = $self->parent;
    my %hash = @_;

    my $res = {
        Author =>
          loc( "%1 (%2)", $self->author->author(), $self->author->email() ),
        Package           => $self->package,
        Description       => $self->description || loc('None given'),
        'Version on CPAN' => $self->version,
    };

    $res->{'Version Installed'} = $self->installed_version
      if $self->installed_version;
    $res->{'Installed File'} = $self->installed_file if $self->installed_file;

    my $i = 0;
    for my $item ( split '', $self->dslip ) {
        $res->{ $cb->_dslip_defs->[$i]->[0] } =
          $cb->_dslip_defs->[$i]->[1]->{$item} || loc('Unknown');
        $i++;
    }

    return $res;
}


sub contains {
    my $self = shift;
    my $cb   = $self->parent;
    my $pkg  = $self->package;

    my @mods = $cb->search( type => 'package', allow => [qr/^$pkg$/] );

    return @mods;
}


sub fetch_report {
    my $self = shift;
    my $cb   = $self->parent;

    return $cb->_query_report( @_, module => $self );
}


sub uninstall {
    my $self = shift;
    my $conf = $self->parent->configure_object();
    my %hash = @_;

    my ( $type, $verbose );
    my $tmpl = {
        type => {
            default => 'all',
            allow   => [qw|man prog all|],
            store   => \$type
        },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        force => { default => $conf->get_conf('force') },
    };

    my $args = check( $tmpl, \%hash ) or return;

    if (
        $conf->get_conf('dist_type')
        and (  ( $conf->get_conf('dist_type') ne INSTALLER_BUILD )
            or ( $conf->get_conf('dist_type') ne INSTALLER_MM ) )
      )
    {
        msg(
            loc(
                "You have a default installer type set (%1) "
                  . "-- you should probably use that package manager to "
                  . "uninstall modules",
                $conf->get_conf('dist_type')
            ),
            $verbose
        );
    }

    unless ( $self->installed_version ) {
        error(
            loc(
                "Module '%1' is not installed, so cannot uninstall",
                $self->module
            )
        );
        return;
    }

    my $files = $self->files( type => $type ) or return;
    my $dirs = $self->directory_tree( type => $type ) or return;
    my $sudo = $conf->get_program('sudo');

    my $pack = $self->packlist;
    $pack = $pack->[0]->packlist_file() if $pack;

    my $flag = 0;
    for my $file ( @$files, $pack ) {
        next unless defined $file && -f $file;

        msg( loc( "Unlinking '%1'", $file ), $verbose );

        my @cmd = ( $^X, "-eunlink+q[$file]" );
        unshift @cmd, $sudo if $sudo;

        my $buffer;
        unless (
            run(
                command => \@cmd,
                verbose => $verbose,
                buffer  => \$buffer
            )
          )
        {
            error( loc( "Failed to unlink '%1': '%2'", $file, $buffer ) );
            $flag++;
        }
    }

    for my $dir ( sort @$dirs ) {
        local *DIR;
        opendir DIR, $dir or next;
        my @count = readdir(DIR);
        close DIR;

        next unless @count == 2;

        msg( loc( "Removing '%1'", $dir ), $verbose );

        my @cmd = ( $^X, "-e", "rmdir q[$dir]" );
        unshift @cmd, $sudo if $sudo;

        my $buffer;
        unless (
            run(
                command => \@cmd,
                verbose => $verbose,
                buffer  => \$buffer
            )
          )
        {
            error( loc( "Failed to rmdir '%1': %2", $dir, $buffer ) );
            $flag++;
        }
    }

    $self->status->uninstall( !$flag );
    $self->status->installed( $flag ? 1 : undef );

    return !$flag;
}


sub distributions {
    my $self = shift;
    my %hash = @_;

    my @list = $self->author->distributions( %hash, module => $self ) or return;

    return grep { $_->package_name eq $self->package_name } @list;
}


for my $sub (qw[files directory_tree packlist validate]) {
    no strict 'refs';
    *$sub = sub {
        return shift->_extutils_installed( @_, method => $sub );
      }
}

sub _extutils_installed {
    my $self = shift;
    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my $home = $cb->_home_dir;
    my %hash = @_;

    my ( $verbose, $type, $method );
    my $tmpl = {
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose,
        },
        type => {
            default => 'all',
            allow   => [qw|prog man all|],
            store   => \$type,
        },
        method => {
            required => 1,
            store    => \$method,
            allow    => [
                qw|files directory_tree packlist
                  validate|
            ],
        },
    };

    my $args = check( $tmpl, \%hash ) or return;

    {
        my $err = ON_OLD_CYGWIN;
        if ($err) { error($err); return }
    }

    return
      unless can_load(
        modules => { 'ExtUtils::Installed' => '0.0' },
        verbose => $verbose,
      );

    my @config_names = (
        {
            lib => 'privlib', arch => 'archlib', prefix => 'prefix', },
        {
            lib    => 'sitelib',
            arch   => 'sitearch',
            prefix => 'siteprefix',
        },
        {
            lib    => 'vendorlib',
            arch   => 'vendorarch',
            prefix => 'vendorprefix',
        },
    );

    my @libs;
    for my $lib ( @{ $conf->get_conf('lib') } ) {
        require Config;

        push @libs, $lib;

        for my $href (@config_names) {
            for my $key (qw[lib arch]) {

                my $dir = $Config::Config{ $href->{$key} . 'exp' } or next;
                my $prefix = $Config::Config{ $href->{prefix} };

                $prefix =~ s/^~/$home/;

                $dir =~ s/^\Q$prefix\E//;

                push @libs, File::Spec->catdir( $lib, $dir );

            }
        }
    }

    my $inst;
    unless ( $inst = ExtUtils::Installed->new( extra_libs => \@libs ) ) {
        error(
            loc( "Could not create an '%1' object", 'ExtUtils::Installed' ) );

        return;
    }

    { my @files;
        eval { @files = $inst->$method( $self->module, $type ) };

        if ($@) {
            chomp $@;
            error(
                loc(
                    "Could not get '%1' for '%2': %3",
                    $method, $self->module, $@
                )
            );
            return;
        }

        return wantarray ? @files : \@files;
    }
}


sub add_to_includepath {
    my $self = shift;
    my $cb   = $self->parent;

    if ( my $dir = $self->status->extract ) {

        $cb->_add_to_includepath(
            directories => [
                File::Spec->catdir( BLIB->($dir), LIB ),
                File::Spec->catdir( BLIB->($dir), ARCH ),
                BLIB->($dir),
            ]
        ) or return;

    }
    else {
        error(
            loc(
                "No extract dir registered for '%1' -- can not add "
                  . "add builddir to search path!",
                $self->module
            )
        );
        return;
    }

    return 1;

}


sub best_path_to_module_build {
    my $self = shift;

    return;
}


1;

__END__

todo:
reports();
