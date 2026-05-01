package Module::Build::Base;

use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;
BEGIN { require 5.00503 }

use Carp;
use Cwd            ();
use File::Copy     ();
use File::Find     ();
use File::Path     ();
use File::Basename ();
use File::Spec 0.82 ();
use File::Compare         ();
use Module::Build::Dumper ();
use IO::File              ();
use Text::ParseWords      ();

use Module::Build::ModuleInfo;
use Module::Build::Notes;
use Module::Build::Config;
use Module::Build::Version;

sub new {
    my $self = shift()->_construct(@_);

    $self->{invoked_action} = $self->{action} ||= 'Build_PL';
    $self->cull_args(@ARGV);

    die
"Too early to specify a build action '$self->{action}'.  Do 'Build $self->{action}' instead.\n"
      if $self->{action} && $self->{action} ne 'Build_PL';

    $self->check_manifest;
    $self->auto_require;
    if ( $self->check_prereq + $self->check_autofeatures != 2 ) {
        $self->log_warn(<<EOF);

ERRORS/WARNINGS FOUND IN PREREQUISITES.  You may wish to install the versions
of the modules indicated above before proceeding with this installation

EOF
        unless ( $self->dist_name eq 'Module-Build'
            || $ENV{PERL5_CPANPLUS_IS_RUNNING}
            || $ENV{PERL5_CPAN_IS_RUNNING} )
        {
            $self->log_warn(
                "Run 'Build installdeps' to install missing prerequisites.\n\n"
            );
        }
    }

    $self->{properties}{_added_to_INC} = [ $self->_added_to_INC ];

    $self->set_bundle_inc;

    $self->dist_name;
    $self->dist_version;
    $self->release_status;
    $self->_guess_module_name unless $self->module_name;

    $self->_find_nested_builds;

    return $self;
}

sub resume {
    my $package = shift;
    my $self    = $package->_construct(@_);
    $self->read_config;

    my @added_earlier = @{ $self->{properties}{_added_to_INC} || [] };

    @INC = ( $self->_added_to_INC, @added_earlier, $self->_default_INC );

    unless ( UNIVERSAL::isa( $package, $self->build_class ) ) {
        my $build_class = $self->build_class;
        my $config_dir  = $self->config_dir || '_build';
        my $build_lib   = File::Spec->catdir( $config_dir, 'lib' );
        unshift( @INC, $build_lib );
        unless ( $build_class->can('new') ) {
            eval "require $build_class; 1"
              or die "Failed to re-load '$build_class': $@";
        }
        return $build_class->resume(@_);
    }

    unless ( $self->_perl_is_same( $self->{properties}{perl} ) ) {
        my $perl = $self->find_perl_interpreter;
        die(<<"DIEFATAL");
* FATAL ERROR: Perl interpreter mismatch. Configuration was initially
  created with '$self->{properties}{perl}'
  but we are now using '$perl'.  You must
  run 'Build realclean' or 'make realclean' and re-configure.
DIEFATAL
    }

    $self->cull_args(@ARGV);

    unless ( $self->allow_mb_mismatch ) {
        my $mb_version = $Module::Build::VERSION;
        if ( $mb_version ne $self->{properties}{mb_version} ) {
            $self->log_warn(<<"MISMATCH");
* WARNING: Configuration was initially created with Module::Build
  version '$self->{properties}{mb_version}' but we are now using version '$mb_version'.
  If errors occur, you must re-run the Build.PL or Makefile.PL script.
MISMATCH
        }
    }

    $self->{invoked_action} = $self->{action} ||= 'build';

    return $self;
}

sub new_from_context {
    my ( $package, %args ) = @_;

    $package->run_perl_script( 'Build.PL', [],
        [ $package->unparse_args( \%args ) ] );
    return $package->resume;
}

sub current {
    local @ARGV;
    return shift()->resume;
}

sub _construct {
    my ( $package, %input ) = @_;

    my $args   = delete $input{args}   || {};
    my $config = delete $input{config} || {};

    my $self = bless {
        args       => {%$args},
        config     => Module::Build::Config->new( values => $config ),
        properties => {
            base_dir   => $package->cwd,
            mb_version => $Module::Build::VERSION,
            %input,
        },
        phash => {},
        stash => {}, },
      $package;

    $self->_set_defaults;
    my ( $p, $ph ) = ( $self->{properties}, $self->{phash} );

    foreach (
        qw(notes config_data features runtime_params cleanup auto_features))
    {
        my $file = File::Spec->catfile( $self->config_dir, $_ );
        $ph->{$_} = Module::Build::Notes->new( file => $file );
        $ph->{$_}->restore if -e $file;
        if ( exists $p->{$_} ) {
            my $vals = delete $p->{$_};
            while ( my ( $k, $v ) = each %$vals ) {
                $self->$_( $k, $v );
            }
        }
    }

    $p->{perl} = $self->find_perl_interpreter
      or $self->log_warn("Warning: Can't locate your perl binary");

    my $blibdir = sub { File::Spec->catdir( $p->{blib}, @_ ) };
    $p->{bindoc_dirs} ||= [ $blibdir->("script") ];
    $p->{libdoc_dirs} ||= [ $blibdir->("lib"), $blibdir->("arch") ];

    $p->{dist_author} = [ $p->{dist_author} ]
      if defined $p->{dist_author} and not ref $p->{dist_author};

    $p->{requires}     = delete $p->{prereq}  if defined $p->{prereq};
    $p->{script_files} = delete $p->{scripts} if defined $p->{scripts};

    for ( 'extra_compiler_flags', 'extra_linker_flags' ) {
        $p->{$_} = [ $self->split_like_shell( $p->{$_} ) ] if exists $p->{$_};
    }

    for ('include_dirs') {
        $p->{$_} = [ $p->{$_} ] if exists $p->{$_} && !ref $p->{$_};
    }

    $self->add_to_cleanup( @{ delete $p->{add_to_cleanup} } )
      if $p->{add_to_cleanup};

    return $self;
}

sub log_info {
    my $self = shift;
    print @_ if ref($self) && ( $self->verbose || !$self->quiet );
}

sub log_verbose {
    my $self = shift;
    print @_ if ref($self) && $self->verbose;
}

sub log_debug {
    my $self = shift;
    print @_ if ref($self) && $self->debug;
}

sub log_warn {
    shift;
    if ( @_ and $_[-1] !~ /\n$/ ) {
        my ( undef, $file, $line ) = caller();
        warn @_, " at $file line $line.\n";
    }
    else {
        warn @_;
    }
}

sub _default_install_paths {
    my $self = shift;
    my $c    = $self->{config};
    my $p    = {};

    my @libstyle =
      $c->get('installstyle')
      ? File::Spec->splitdir( $c->get('installstyle') )
      : qw(lib perl5);
    my $arch    = $c->get('archname');
    my $version = $c->get('version');

    my $bindoc = $c->get('installman1dir') || undef;
    my $libdoc = $c->get('installman3dir') || undef;

    my $binhtml =
         $c->get('installhtml1dir')
      || $c->get('installhtmldir')
      || undef;
    my $libhtml =
         $c->get('installhtml3dir')
      || $c->get('installhtmldir')
      || undef;

    $p->{install_sets} = {
        core => {
            lib     => $c->get('installprivlib'),
            arch    => $c->get('installarchlib'),
            bin     => $c->get('installbin'),
            script  => $c->get('installscript'),
            bindoc  => $bindoc,
            libdoc  => $libdoc,
            binhtml => $binhtml,
            libhtml => $libhtml,
        },
        site => {
            lib    => $c->get('installsitelib'),
            arch   => $c->get('installsitearch'),
            bin    => $c->get('installsitebin') || $c->get('installbin'),
            script => $c->get('installsitescript')
              || $c->get('installsitebin')
              || $c->get('installscript'),
            bindoc  => $c->get('installsiteman1dir')  || $bindoc,
            libdoc  => $c->get('installsiteman3dir')  || $libdoc,
            binhtml => $c->get('installsitehtml1dir') || $binhtml,
            libhtml => $c->get('installsitehtml3dir') || $libhtml,
        },
        vendor => {
            lib    => $c->get('installvendorlib'),
            arch   => $c->get('installvendorarch'),
            bin    => $c->get('installvendorbin') || $c->get('installbin'),
            script => $c->get('installvendorscript')
              || $c->get('installvendorbin')
              || $c->get('installscript'),
            bindoc  => $c->get('installvendorman1dir')  || $bindoc,
            libdoc  => $c->get('installvendorman3dir')  || $libdoc,
            binhtml => $c->get('installvendorhtml1dir') || $binhtml,
            libhtml => $c->get('installvendorhtml3dir') || $libhtml,
        },
    };

    $p->{original_prefix} = {
        core => $c->get('installprefixexp')
          || $c->get('installprefix')
          || $c->get('prefixexp')
          || $c->get('prefix')
          || '',
        site   => $c->get('siteprefixexp'),
        vendor => $c->get('usevendorprefix') ? $c->get('vendorprefixexp') : '',
    };
    $p->{original_prefix}{site} ||= $p->{original_prefix}{core};

    $p->{install_base_relpaths} = {
        lib  => [ 'lib', 'perl5' ],
        arch => [ 'lib', 'perl5', $arch ],
        bin     => ['bin'],
        script  => ['bin'],
        bindoc  => [ 'man', 'man1' ],
        libdoc  => [ 'man', 'man3' ],
        binhtml => ['html'],
        libhtml => ['html'],
    };

    $p->{prefix_relpaths} = {
        core => {
            lib    => [@libstyle],
            arch   => [ @libstyle, $version, $arch ],
            bin    => ['bin'],
            script => ['bin'],
            bindoc  => [ 'man', 'man1' ],
            libdoc  => [ 'man', 'man3' ],
            binhtml => ['html'],
            libhtml => ['html'],
        },
        vendor => {
            lib    => [@libstyle],
            arch   => [ @libstyle, $version, $arch ],
            bin    => ['bin'],
            script => ['bin'],
            bindoc  => [ 'man', 'man1' ],
            libdoc  => [ 'man', 'man3' ],
            binhtml => ['html'],
            libhtml => ['html'],
        },
        site => {
            lib  => [ @libstyle, 'site_perl' ],
            arch => [ @libstyle, 'site_perl', $version, $arch ],
            bin     => ['bin'],
            script  => ['bin'],
            bindoc  => [ 'man', 'man1' ],
            libdoc  => [ 'man', 'man3' ],
            binhtml => ['html'],
            libhtml => ['html'],
        },
    };
    return $p;
}

sub _find_nested_builds {
    my $self = shift;
    my $r = $self->recurse_into or return;

    my ( $file, @r );
    if ( !ref($r) && $r eq 'auto' ) {
        local *DH;
        opendir DH, $self->base_dir
          or die "Can't scan directory "
          . $self->base_dir
          . " for nested builds: $!";
        while ( defined( $file = readdir DH ) ) {
            my $subdir = File::Spec->catdir( $self->base_dir, $file );
            next unless -d $subdir;
            push @r, $subdir if -e File::Spec->catfile( $subdir, 'Build.PL' );
        }
    }

    $self->recurse_into( \@r );
}

sub cwd {
    return Cwd::cwd();
}

sub _quote_args {
    my ( $self, @args ) = @_;

    my @quoted;

    for (@args) {
        if (/^[^\s*?!\$<>;\\|'"\[\]\{\}]+$/) {
            push @quoted, $_;
        }
        else {
            s/('+)/'"$1"'/g;
            push @quoted, qq('$_');
        }
    }

    return join " ", @quoted;
}

sub _backticks {
    my ( $self, @cmd ) = @_;
    if ( $self->have_forkpipe ) {
        local *FH;
        my $pid = open *FH, "-|";
        if ($pid) {
            return wantarray ? <FH> : join '', <FH>;
        }
        else {
            die "Can't execute @cmd: $!\n" unless defined $pid;
            exec { $cmd[0] } @cmd;
        }
    }
    else {
        my $cmd = $self->_quote_args(@cmd);
        return `$cmd`;
    }
}

sub have_forkpipe { 1 }

sub _perl_is_same {
    my ( $self, $perl ) = @_;

    my @cmd = ($perl);

    if ( $ENV{PERL_CORE} ) {
        push @cmd,
          '-I' . File::Spec->catdir( File::Basename::dirname($perl), 'lib' );
    }

    push @cmd, qw(-MConfig=myconfig -e print -e myconfig);
    return $self->_backticks(@cmd) eq Config->myconfig;
}

{
    my $known_perl;

    sub find_perl_interpreter {
        my $self = shift;

        return $known_perl if defined($known_perl);
        return $known_perl = $self->_discover_perl_interpreter;
    }
}

sub _discover_perl_interpreter {
    my $proto = shift;
    my $c = ref($proto) ? $proto->{config} : 'Module::Build::Config';

    my $perl          = $^X;
    my $perl_basename = File::Basename::basename($perl);

    my @potential_perls;

    push( @potential_perls, $perl )
      if File::Spec->file_name_is_absolute($perl);

    my $abs_perl = File::Spec->rel2abs($perl);
    push( @potential_perls, $abs_perl );

    if ( $ENV{PERL_CORE} ) {

        require ExtUtils::CBuilder;
        my $perl_src = Cwd::realpath( ExtUtils::CBuilder->perl_src );
        if ( defined($perl_src) && length($perl_src) ) {
            my $uninstperl =
              File::Spec->rel2abs(
                File::Spec->catfile( $perl_src, $perl_basename ) );
            push( @potential_perls, $uninstperl );
        }

    }
    else {

        push( @potential_perls, $c->get('perlpath') );

        push( @potential_perls,
            map File::Spec->catfile( $_, $perl_basename ),
            File::Spec->path() );
    }

    my $exe = $c->get('exe_ext');
    foreach my $thisperl (@potential_perls) {

        if ( defined $exe ) {
            $thisperl .= $exe unless $thisperl =~ m/$exe$/i;
        }

        if ( -f $thisperl && $proto->_perl_is_same($thisperl) ) {
            return $thisperl;
        }
    }

    my @paths = map File::Basename::dirname($_), @potential_perls;
    die "Can't locate the perl binary used to run this script "
      . "in (@paths)\n";
}

sub find_command {
    my ( $self, $command ) = @_;

    if ( File::Spec->file_name_is_absolute($command) ) {
        return $self->_maybe_command($command);

    }
    else {
        for my $dir ( File::Spec->path ) {
            my $abs = File::Spec->catfile( $dir, $command );
            return $abs if $abs = $self->_maybe_command($abs);
        }
    }
}

sub _maybe_command {
    my ( $self, $file ) = @_;
    return $file if -x $file && !-d $file;
    return;
}

sub _is_interactive {
    return -t STDIN && ( -t STDOUT || !( -f STDOUT || -c STDOUT ) );
}

sub _is_unattended {
    my $self = shift;
    return $ENV{PERL_MM_USE_DEFAULT}
      || ( !$self->_is_interactive && eof STDIN );
}

sub _readline {
    my $self = shift;
    return undef if $self->_is_unattended;

    my $answer = <STDIN>;
    chomp $answer if defined $answer;
    return $answer;
}

sub prompt {
    my $self = shift;
    my $mess = shift
      or die "prompt() called without a prompt message";

    my @def;
    @def = (shift) if @_;
    my @dispdef =
      scalar(@def)
      ? ( '[', ( defined( $def[0] ) ? $def[0] . ' ' : '' ), ']' )
      : ( ' ', '' );

    local $| = 1;
    print "$mess ", @dispdef;

    if ( $self->_is_unattended && !@def ) {
        die <<EOF;
ERROR: This build seems to be unattended, but there is no default value
for this question.  Aborting.
EOF
    }

    my $ans = $self->_readline();

    if ( !defined($ans) or !length($ans) ) { print "$dispdef[1]\n";
        $ans = scalar(@def) ? $def[0] : '';
    }

    return $ans;
}

sub y_n {
    my $self = shift;
    my ( $mess, $def ) = @_;

    die "y_n() called without a prompt message" unless $mess;
    die "Invalid default value: y_n() default must be 'y' or 'n'"
      if $def && $def !~ /^[yn]/i;

    my $answer;
    while (1) { $answer = $self->prompt(@_);
        return 1 if $answer =~ /^y/i;
        return 0 if $answer =~ /^n/i;
        local $| = 1;
        print "Please answer 'y' or 'n'.\n";
    }
}

sub current_action { shift->{action} }
sub invoked_action { shift->{invoked_action} }

sub notes       { shift()->{phash}{notes}->access(@_) }
sub config_data { shift()->{phash}{config_data}->access(@_) }

sub runtime_params {
    shift->{phash}{runtime_params}->read( @_ ? shift : () );
} sub auto_features { shift()->{phash}{auto_features}->access(@_) }

sub features {
    my $self = shift;
    my $ph   = $self->{phash};

    if (@_) {
        my $key = shift;
        if ( $ph->{features}->exists($key) ) {
            return $ph->{features}->access( $key, @_ );
        }

        if ( my $info = $ph->{auto_features}->access($key) ) {
            my $disabled;
            for my $type ( @{ $self->prereq_action_types } ) {
                next
                  if $type eq 'description'
                  || $type eq 'recommends'
                  || !exists $info->{$type};
                my $prereqs = $info->{$type};
                for my $modname ( sort keys %$prereqs ) {
                    my $spec = $prereqs->{$modname};
                    my $status =
                      $self->check_installed_status( $modname, $spec );
                    if ( ( !$status->{ok} ) xor( $type =~ /conflicts$/ ) ) {
                        return 0;
                    }
                    if ( !eval "require $modname; 1" ) { return 0; }
                }
            }
            return 1;
        }

        return $ph->{features}->access( $key, @_ );
    }

    my %features;
    my %auto_features = $ph->{auto_features}->access();
    while ( my ( $name, $info ) = each %auto_features ) {
        my $failures = $self->prereq_failures($info);
        my $disabled =
          grep( /^(?:\w+_)?(?:requires|conflicts)$/, keys %$failures ) ? 1 : 0;
        $features{$name} = $disabled ? 0 : 1;
    }
    %features = ( %features, $ph->{features}->access() );

    return wantarray ? %features : \%features;
}
BEGIN { *feature = \&features }

sub _mb_feature {
    my $self = shift;

    if ( ( $self->module_name || '' ) eq 'Module::Build' ) {
        return $self->feature(@_);
    }
    else {
        require Module::Build::ConfigData;
        return Module::Build::ConfigData->feature(@_);
    }
}

sub _warn_mb_feature_deps {
    my $self = shift;
    my $name = shift;
    $self->log_warn(
            "The '$name' feature is not available.  Please install missing\n"
          . "feature dependencies and try again.\n"
          . $self->_feature_deps_msg($name)
          . "\n" );
}

sub add_build_element {
    my ( $self, $elem ) = @_;
    my $elems = $self->build_elements;
    push @$elems, $elem unless grep { $_ eq $elem } @$elems;
}

sub ACTION_config_data {
    my $self = shift;
    return unless $self->has_config_data;

    my $module_name = $self->module_name
      or die "The config_data feature requires that 'module_name' be set";
    my $notes_name = $module_name . '::ConfigData';
    my $notes_pm =
      File::Spec->catfile( $self->blib, 'lib', split /::/, "$notes_name.pm" );

    return
      if $self->up_to_date(
        [
            'Build.PL', $self->config_file('config_data'),
            $self->config_file('features')
        ],
        $notes_pm
      );

    $self->log_verbose("Writing config notes to $notes_pm\n");
    File::Path::mkpath( File::Basename::dirname($notes_pm) );

    Module::Build::Notes->write_config_data(
        file          => $notes_pm,
        module        => $module_name,
        config_module => $notes_name,
        config_data   => scalar $self->config_data,
        feature       => scalar $self->{phash}{features}->access(),
        auto_features => scalar $self->auto_features,
    );
}

{ my %valid_properties = ( __PACKAGE__, {} );
    my %additive_properties;

    sub _mb_classes {
        my $class = ref( $_[0] ) || $_[0];
        return ( $class, $class->mb_parents );
    }

    sub valid_property {
        my ( $class, $prop ) = @_;
        return grep exists( $valid_properties{$_}{$prop} ), $class->_mb_classes;
    }

    sub valid_properties {
        return keys %{ shift->valid_properties_defaults() };
    }

    sub valid_properties_defaults {
        my %out;
        for my $class ( reverse shift->_mb_classes ) {
            @out{ keys %{ $valid_properties{$class} } } =
              map { $_->() } values %{ $valid_properties{$class} };
        }
        return \%out;
    }

    sub array_properties {
        for ( shift->_mb_classes ) {
            return @{ $additive_properties{$_}->{ARRAY} }
              if exists $additive_properties{$_}->{ARRAY};
        }
    }

    sub hash_properties {
        for ( shift->_mb_classes ) {
            return @{ $additive_properties{$_}->{'HASH'} }
              if exists $additive_properties{$_}->{'HASH'};
        }
    }

    sub add_property {
        my ( $class, $property ) = ( shift, shift );
        die "Property '$property' already exists"
          if $class->valid_property($property);
        my %p = @_ == 1 ? ( default => shift ) : @_;

        my $type = ref $p{default};
        $valid_properties{$class}{$property} =
            $type eq 'CODE' ? $p{default}
          : $type eq 'HASH' ? sub { return { %{ $p{default} } } }
          : $type eq 'ARRAY' ? sub { return [ @{ $p{default} } ] }
          :                    sub { return $p{default} };

        push @{ $additive_properties{$class}->{$type} }, $property
          if $type;

        unless ( $class->can($property) ) {
            my $sub =
              $type eq 'HASH'
              ? _make_hash_accessor( $property, \%p )
              : _make_accessor( $property, \%p );
            no strict 'refs';
            *{"$class\::$property"} = $sub;
        }

        return $class;
    }

    sub property_error {
        my $self = shift;
        die 'ERROR: ', @_;
    }

    sub _set_defaults {
        my $self = shift;

        $self->{properties}{build_class} ||= ref $self;

        $self->{properties}{orig_dir} ||= $self->{properties}{base_dir};

        my $defaults = $self->valid_properties_defaults;

        foreach my $prop ( keys %$defaults ) {
            $self->{properties}{$prop} = $defaults->{$prop}
              unless exists $self->{properties}{$prop};
        }

        for my $prop ( $self->array_properties ) {
            $self->{properties}{$prop} = [ @{ $defaults->{$prop} } ]
              unless exists $self->{properties}{$prop};
        }
        for my $prop ( $self->hash_properties ) {
            $self->{properties}{$prop} = { %{ $defaults->{$prop} } }
              unless exists $self->{properties}{$prop};
        }
    }

} sub _make_hash_accessor {
    my ( $property, $p ) = @_;
    my $check = $p->{check} || sub { 1 };

    return sub {
        my $self = shift;

        unless ( ref($self) ) {
            carp("\n$property not a class method (@_)");
            return;
        }

        my $x = $self->{properties};
        return $x->{$property} unless @_;

        my $prop = $x->{$property};
        if ( defined $_[0] && !ref $_[0] ) {
            if ( @_ == 1 ) {
                return exists $prop->{ $_[0] } ? $prop->{ $_[0] } : undef;
            }
            elsif ( @_ % 2 == 0 ) {
                my %new = ( %{$prop}, @_ );
                local $_ = \%new;
                $x->{$property} = \%new if $check->($self);
                return $x->{$property};
            }
            else {
                die "Unexpected arguments for property '$property'\n";
            }
        }
        else {
            die "Unexpected arguments for property '$property'\n"
              if defined $_[0] && ref $_[0] ne 'HASH';
            local $_ = $_[0];
            $x->{$property} = shift if $check->($self);
        }
    };
}

sub _make_accessor {
    my ( $property, $p ) = @_;
    my $check = $p->{check} || sub { 1 };

    return sub {
        my $self = shift;

        unless ( ref($self) ) {
            carp("\n$property not a class method (@_)");
            return;
        }

        my $x = $self->{properties};
        return $x->{$property} unless @_;
        local $_ = $_[0];
        $x->{$property} = shift if $check->($self);
        return $x->{$property};
    };
}

__PACKAGE__->add_property( auto_configure_requires => 1 );
__PACKAGE__->add_property( blib                    => 'blib' );
__PACKAGE__->add_property( build_class             => 'Module::Build' );
__PACKAGE__->add_property(
    build_elements => [qw(PL support pm xs share_dir pod script)] );
__PACKAGE__->add_property( build_script       => 'Build' );
__PACKAGE__->add_property( build_bat          => 0 );
__PACKAGE__->add_property( bundle_inc         => [] );
__PACKAGE__->add_property( bundle_inc_preload => [] );
__PACKAGE__->add_property( config_dir         => '_build' );
__PACKAGE__->add_property( dynamic_config     => 1 );
__PACKAGE__->add_property( include_dirs       => [] );
__PACKAGE__->add_property( license            => 'unknown' );
__PACKAGE__->add_property( metafile           => 'META.yml' );
__PACKAGE__->add_property( mymetafile         => 'MYMETA.yml' );
__PACKAGE__->add_property( metafile2          => 'META.json' );
__PACKAGE__->add_property( mymetafile2        => 'MYMETA.json' );
__PACKAGE__->add_property( recurse_into       => [] );
__PACKAGE__->add_property( use_rcfile         => 1 );
__PACKAGE__->add_property( create_packlist    => 1 );
__PACKAGE__->add_property( allow_mb_mismatch  => 0 );
__PACKAGE__->add_property( config             => undef );
__PACKAGE__->add_property( test_file_exts     => ['.t'] );
__PACKAGE__->add_property( use_tap_harness    => 0 );
__PACKAGE__->add_property( cpan_client        => 'cpan' );
__PACKAGE__->add_property( tap_harness_args   => {} );
__PACKAGE__->add_property(
    'installdirs',
    default => 'site',
    check   => sub {
        return 1 if /^(core|site|vendor)$/;
        return shift->property_error(
            $_ eq 'perl'
            ? 'Perhaps you meant installdirs to be "core" rather than "perl"?'
            : 'installdirs must be one of "core", "site", or "vendor"'
        );
        return shift->property_error("Perhaps you meant 'core'?")
          if $_ eq 'perl';
        return 0;
    },
);

{
    __PACKAGE__->add_property( html_css => '' );
}

{
    my @prereq_action_types = qw(requires build_requires conflicts recommends);
    foreach my $type (@prereq_action_types) {
        __PACKAGE__->add_property( $type => {} );
    }
    __PACKAGE__->add_property( prereq_action_types => \@prereq_action_types );
}

__PACKAGE__->add_property( $_ => {} ) for qw(
  get_options
  install_base_relpaths
  install_path
  install_sets
  meta_add
  meta_merge
  original_prefix
  prefix_relpaths
  configure_requires
);

__PACKAGE__->add_property($_) for qw(
  PL_files
  autosplit
  base_dir
  bindoc_dirs
  c_source
  create_license
  create_makefile_pl
  create_readme
  debugger
  destdir
  dist_abstract
  dist_author
  dist_name
  dist_suffix
  dist_version
  dist_version_from
  extra_compiler_flags
  extra_linker_flags
  has_config_data
  install_base
  libdoc_dirs
  magic_number
  mb_version
  module_name
  needs_compiler
  orig_dir
  perl
  pm_files
  pod_files
  pollute
  prefix
  program_name
  quiet
  recursive_test_files
  release_status
  script_files
  scripts
  share_dir
  sign
  test_files
  verbose
  debug
  xs_files
);

sub config {
    my $self = shift;
    my $c = ref($self) ? $self->{config} : 'Module::Build::Config';
    return $c->all_config unless @_;

    my $key = shift;
    return $c->get($key) unless @_;

    my $val = shift;
    return $c->set( $key => $val );
}

sub mb_parents {
    my @in_stack = (shift);
    my %seen = ( $in_stack[0] => 1 );

    my ( $current, @out );
    while (@in_stack) {
        next
          unless defined( $current = shift @in_stack )
          && $current->isa('Module::Build::Base');
        push @out, $current;
        next if $current eq 'Module::Build::Base';
        no strict 'refs';
        unshift @in_stack, map {
            my $c = $_;
            substr( $c, 0, 2 ) = "main::" if substr( $c, 0, 2 ) eq '::';
            $seen{$c}++ ? () : $c;
        } @{"$current\::ISA"};

    }
    shift @out;
    return @out;
}

sub extra_linker_flags   { shift->_list_accessor( 'extra_linker_flags',   @_ ) }
sub extra_compiler_flags { shift->_list_accessor( 'extra_compiler_flags', @_ ) }

sub _list_accessor {
    ( my $self, local $_ ) = ( shift, shift );
    my $p = $self->{properties};
    $p->{$_} = [@_] if @_;
    $p->{$_} = [] unless exists $p->{$_};
    return ref( $p->{$_} ) ? $p->{$_} : [ $p->{$_} ];
}

sub subclass {
    my ( $pack, %opts ) = @_;

    my $build_dir = '_build';
    $pack->delete_filetree($build_dir) if -e $build_dir;

    die "Must provide 'code' or 'class' option to subclass()\n"
      unless $opts{code}
      or $opts{class};

    $opts{code}  ||= '';
    $opts{class} ||= 'MyModuleBuilder';

    my $filename =
      File::Spec->catfile( $build_dir, 'lib', split '::', $opts{class} )
      . '.pm';
    my $filedir = File::Basename::dirname($filename);
    $pack->log_verbose("Creating custom builder $filename in $filedir\n");

    File::Path::mkpath($filedir);
    die "Can't create directory $filedir: $!" unless -d $filedir;

    my $fh = IO::File->new("> $filename") or die "Can't create $filename: $!";
    print $fh <<EOF;
package $opts{class};
use $pack;
\@ISA = qw($pack);
$opts{code}
1;
EOF
    close $fh;

    unshift @INC, File::Spec->catdir( File::Spec->rel2abs($build_dir), 'lib' );
    eval "use $opts{class}";
    die $@ if $@;

    return $opts{class};
}

sub _guess_module_name {
    my $self = shift;
    my $p    = $self->{properties};
    return if $p->{module_name};
    if ( $p->{dist_version_from} && -e $p->{dist_version_from} ) {
        my $mi =
          Module::Build::ModuleInfo->new_from_file( $self->dist_version_from );
        $p->{module_name} = $mi->name;
    }
    else {
        my $mod_path = my $mod_name = $p->{dist_name};
        $mod_name =~ s{-}{::}g;
        $mod_path =~ s{-}{/}g;
        $mod_path .= ".pm";
        if ( -e $mod_path || -e "lib/$mod_path" ) {
            $p->{module_name} = $mod_name;
        }
        else {
            $self->log_warn( << 'END_WARN' );
No 'module_name' was provided and it could not be inferred
from other properties.  This will prevent a packlist from
being written for this file.  Please set either 'module_name'
or 'dist_version_from' in Build.PL.
END_WARN
        }
    }
}

sub dist_name {
    my $self = shift;
    my $p    = $self->{properties};
    return $p->{dist_name} if defined $p->{dist_name};

    die
"Can't determine distribution name, must supply either 'dist_name' or 'module_name' parameter"
      unless $self->module_name;

    ( $p->{dist_name} = $self->module_name ) =~ s/::/-/g;

    return $p->{dist_name};
}

sub release_status {
    my ($self) = @_;
    my $p = $self->{properties};

    if ( !defined $p->{release_status} ) {
        $p->{release_status} = $self->_is_dev_version ? 'testing' : 'stable';
    }

    unless ( $p->{release_status} =~ qr/\A(?:stable|testing|unstable)\z/ ) {
        die "Illegal value '$p->{release_status}' for release_status\n";
    }

    if ( $p->{release_status} eq 'stable' && $self->_is_dev_version ) {
        my $version = $self->dist_version;
        die "Illegal value '$p->{release_status}' with version '$version'\n";
    }
    return $p->{release_status};
}

sub dist_suffix {
    my ($self) = @_;
    my $p = $self->{properties};
    return $p->{dist_suffix} if defined $p->{dist_suffix};

    if ( $self->release_status eq 'stable' ) {
        $p->{dist_suffix} = "";
    }
    else {
        $p->{dist_suffix} = $self->_is_dev_version ? "" : "TRIAL";
    }

    return $p->{dist_suffix};
}

sub dist_version_from {
    my ($self) = @_;
    my $p = $self->{properties};
    if ( $self->module_name ) {
        $p->{dist_version_from} ||=
          join( '/', 'lib', split( /::/, $self->module_name ) ) . '.pm';
    }
    return $p->{dist_version_from} || undef;
}

sub dist_version {
    my ($self) = @_;
    my $p = $self->{properties};

    return $p->{dist_version} if defined $p->{dist_version};

    if ( my $dist_version_from = $self->dist_version_from ) {
        my $version_from =
          File::Spec->catfile( split( qr{/}, $dist_version_from ) );
        my $pm_info = Module::Build::ModuleInfo->new_from_file($version_from)
          or die "Can't find file $version_from to determine version";
        $p->{dist_version} = $self->normalize_version( $pm_info->version() );
        unless ( defined $p->{dist_version} ) {
            die "Can't determine distribution version from $version_from";
        }
    }

    die(
"Can't determine distribution version, must supply either 'dist_version',\n"
          . "'dist_version_from', or 'module_name' parameter" )
      unless defined $p->{dist_version};

    return $p->{dist_version};
}

sub _is_dev_version {
    my ($self) = @_;
    my $dist_version = $self->dist_version;
    my $version_obj = eval { Module::Build::Version->new($dist_version) };
    return $@ ? 0 : $version_obj->is_alpha;
}

sub dist_author   { shift->_pod_parse('author') }
sub dist_abstract { shift->_pod_parse('abstract') }

sub _pod_parse {
    my ( $self, $part ) = @_;
    my $p      = $self->{properties};
    my $member = "dist_$part";
    return $p->{$member} if defined $p->{$member};

    my $docfile = $self->_main_docfile
      or return;
    my $fh = IO::File->new($docfile)
      or return;

    require Module::Build::PodParser;
    my $parser = Module::Build::PodParser->new( fh => $fh );
    my $method = "get_$part";
    return $p->{$member} = $parser->$method();
}

sub version_from_file { return Module::Build::ModuleInfo->new_from_file( $_[1] )
      ->version();
}

sub find_module_by_name { return
      Module::Build::ModuleInfo->find_module_by_name( @_[ 1, 2 ] );
}

{
    my %unlink_list_for_pid;

    sub _unlink_on_exit {
        my $self = shift;
        for my $f (@_) {
            push @{ $unlink_list_for_pid{$$} }, $f if -f $f;
        }
        return 1;
    }

    END {
        for my $f ( map glob($_), @{ $unlink_list_for_pid{$$} || [] } ) {
            next unless -e $f;
            File::Path::rmtree( $f, 0, 0 );
        }
    }
}

sub add_to_cleanup {
    my $self = shift;
    my %files = map { $self->localize_file_path($_), 1 } @_;
    $self->{phash}{cleanup}->write( \%files );
}

sub cleanup {
    my $self = shift;
    my $all  = $self->{phash}{cleanup}->read;
    return keys %$all;
}

sub config_file {
    my $self = shift;
    return unless -d $self->config_dir;
    return File::Spec->catfile( $self->config_dir, @_ );
}

sub read_config {
    my ($self) = @_;

    my $file = $self->config_file('build_params')
      or die "Can't find 'build_params' in " . $self->config_dir;
    my $fh = IO::File->new($file) or die "Can't read '$file': $!";
    my $ref = eval do { local $/; <$fh> };
    die if $@;
    my $c;
    ( $self->{args}, $c, $self->{properties} ) = @$ref;
    $self->{config} = Module::Build::Config->new( values => $c );
    close $fh;
}

sub has_config_data {
    my $self = shift;
    return scalar grep $self->{phash}{$_}->has_data(),
      qw(config_data features auto_features);
}

sub _write_data {
    my ( $self, $filename, $data ) = @_;

    my $file = $self->config_file($filename);
    my $fh = IO::File->new("> $file") or die "Can't create '$file': $!";
    unless ( ref($data) ) { print $fh $data;
        return;
    }

    print {$fh} Module::Build::Dumper->_data_dump($data);
}

sub write_config {
    my ($self) = @_;

    File::Path::mkpath( $self->{properties}{config_dir} );
    -d $self->{properties}{config_dir}
      or die "Can't mkdir $self->{properties}{config_dir}: $!";

    my @items = @{ $self->prereq_action_types };
    $self->_write_data( 'prereqs', { map { $_, $self->$_() } @items } );
    $self->_write_data( 'build_params',
        [ $self->{args}, $self->{config}->values_set, $self->{properties} ] );

    $self->_write_data( 'magicnum', $self->magic_number( int rand 1_000_000 ) );

    $self->{phash}{$_}->write()
      foreach
      qw(notes cleanup features auto_features config_data runtime_params);
}

{
    my %packlist_map = (
        '^File::Spec'      => 'Cwd',
        '^Devel::AssertOS' => 'Devel::CheckOS',
    );

    sub _find_packlist {
        my ( $self, $inst, $mod ) = @_;
        my $lookup = $mod;
        my $packlist = eval { $inst->packlist($lookup) };
        if ( !$packlist ) {
            while ( my ( $re, $new_mod ) = each %packlist_map ) {
                if ( $mod =~ qr/$re/ ) {
                    $lookup = $new_mod;
                    $packlist = eval { $inst->packlist($lookup) };
                    last;
                }
            }
        }
        return $packlist ? $lookup : undef;
    }

    sub set_bundle_inc {
        my $self = shift;

        my $bundle_inc         = $self->{properties}{bundle_inc};
        my $bundle_inc_preload = $self->{properties}{bundle_inc_preload};
        return unless inc::latest->can('loaded_modules');
        require ExtUtils::Installed;
        my $inst = eval { ExtUtils::Installed->new( extra_libs => [@INC] ) };
        if ($@) {
            $self->log_warn( << "EUI_ERROR" );
Bundling in inc/ is disabled because ExtUtils::Installed could not
create a list of your installed modules.  Here is the error:
$@
EUI_ERROR
            return;
        }
        my @bundle_list = map { [ $_, 0 ] } inc::latest->loaded_modules;

        while (@bundle_list) {
            my ( $mod, $prereq ) = @{ shift @bundle_list };

            my $lookup = $self->_find_packlist( $inst, $mod );
            if ( !$lookup ) {
                die << "NO_PACKLIST";
Could not find a packlist for '$mod'.  If it's a core module, try
force installing it from CPAN.
NO_PACKLIST
            }
            else {
                push @{ $prereq ? $bundle_inc_preload : $bundle_inc }, $lookup;
            }
        }
    }
}

sub check_autofeatures {
    my ($self) = @_;
    my $features = $self->auto_features;

    return 1 unless %$features;

    my $longest = sub {
        my @str = @_ or croak("no strings given");

        my @len = map( { length($_) } @str );
        my $max = 0;
        my $longest;
        for my $i ( 0 .. $#len ) {
            ( $max, $longest ) = ( $len[$i], $str[$i] ) if ( $len[$i] > $max );
        }
        return ($longest);
    };
    my $max_name_len = length( $longest->( keys %$features ) );

    my ( $num_disabled, $log_text ) =
      ( 0, "\nChecking optional features...\n" );
    for my $name ( sort keys %$features ) {
        $log_text .= $self->_feature_deps_msg( $name, $max_name_len );
    }

    $num_disabled = () = $log_text =~ /disabled/g;

    if ($num_disabled) {
        $self->log_warn($log_text);
        return 0;
    }
    else {
        $self->log_verbose($log_text);
        return 1;
    }
}

sub _feature_deps_msg {
    my ( $self, $name, $max_name_len ) = @_;
    $max_name_len ||= length $name;
    my $features     = $self->auto_features;
    my $info         = $features->{$name};
    my $feature_text = "$name" . '.' x ( $max_name_len - length($name) + 4 );

    my ( $log_text, $disabled ) = ( '', '' );
    if ( my $failures = $self->prereq_failures($info) ) {
        $disabled =
          grep( /^(?:\w+_)?(?:requires|conflicts)$/, keys %$failures ) ? 1 : 0;
        $feature_text .= $disabled ? "disabled\n" : "enabled\n";

        for my $type ( @{ $self->prereq_action_types } ) {
            next unless exists $failures->{$type};
            $feature_text .= "  $type:\n";
            my $prereqs = $failures->{$type};
            for my $module ( sort keys %$prereqs ) {
                my $status = $prereqs->{$module};
                my $required =
                  ( $type =~ /^(?:\w+_)?(?:requires|conflicts)$/ ) ? 1 : 0;
                my $prefix = ($required) ? '!' : '*';
                $feature_text .= "    $prefix $status->{message}\n";
            }
        }
    }
    else {
        $feature_text .= "enabled\n";
    }
    $log_text .= $feature_text if $disabled || $self->verbose;
    return $log_text;
}

sub auto_config_requires {
    my ($self) = @_;
    my $p = $self->{properties};

    if (   $self->dist_name ne 'Module-Build'
        && $self->auto_configure_requires
        && !exists $p->{configure_requires}{'Module::Build'} )
    {
        ( my $ver = $VERSION ) =~ s/^(\d+\.\d\d).*$/$1/;
        $self->log_warn(<<EOM);
Module::Build was not found in configure_requires! Adding it now
automatically as: configure_requires => { 'Module::Build' => $ver }
EOM
        $self->_add_prereq( 'configure_requires', 'Module::Build', $ver );
    }

    if ( inc::latest->can('loaded_module') ) {
        for my $mod ( inc::latest->loaded_modules ) {
            next if exists $p->{configure_requires}{$mod};
            $self->_add_prereq( 'configure_requires', $mod, $mod->VERSION );
        }
    }

    return;
}

sub auto_require {
    my ($self) = @_;
    my $p = $self->{properties};

    my $xs_files = $self->find_xs_files;
    if ( !defined $p->{needs_compiler} ) {
        $self->needs_compiler( keys %$xs_files || defined $self->c_source );
    }
    if ( $self->needs_compiler ) {
        $self->_add_prereq( 'build_requires', 'ExtUtils::CBuilder', 0 );
        if ( !$self->have_c_compiler ) {
            $self->log_warn(<<'EOM');
Warning: ExtUtils::CBuilder not installed or no compiler detected
Proceeding with configuration, but compilation may fail during Build

EOM
        }
    }

    if ( $self->share_dir ) {
        $self->_add_prereq( 'requires', 'File::ShareDir', '1.00' );
    }

    return;
}

sub _add_prereq {
    my ( $self, $type, $module, $version ) = @_;
    my $p = $self->{properties};
    $version = 0 unless defined $version;
    if ( exists $p->{$type}{$module} ) {
        return
          if $self->compare_versions( $version, '<=', $p->{$type}{$module} );
    }
    $self->log_verbose("Adding to $type\: $module => $version\n");
    $p->{$type}{$module} = $version;
    return 1;
}

sub prereq_failures {
    my ( $self, $info ) = @_;

    my @types = @{ $self->prereq_action_types };
    $info ||= { map { $_, $self->$_() } @types };

    my $out;

    foreach my $type (@types) {
        my $prereqs = $info->{$type};
        for my $modname ( keys %$prereqs ) {
            my $spec = $prereqs->{$modname};
            my $status = $self->check_installed_status( $modname, $spec );

            if ( $type =~ /^(?:\w+_)?conflicts$/ ) {
                next if !$status->{ok};
                $status->{conflicts} = delete $status->{need};
                $status->{message} =
                  "$modname ($status->{have}) conflicts with this distribution";

            }
            elsif ( $type =~ /^(?:\w+_)?recommends$/ ) {
                next if $status->{ok};
                $status->{message} = (
                    !ref( $status->{have} )
                      && $status->{have} eq '<none>'
                    ? "$modname is not installed"
                    : "$modname ($status->{have}) is installed, but we prefer to have $spec"
                );
            }
            else {
                next if $status->{ok};
            }

            $out->{$type}{$modname} = $status;
        }
    }

    return $out;
}

sub _enum_prereqs {
    my $self = shift;
    my %prereqs;
    foreach my $type ( @{ $self->prereq_action_types } ) {
        if ( $self->can($type) ) {
            my $prereq = $self->$type() || {};
            $prereqs{$type} = $prereq if %$prereq;
        }
    }
    return \%prereqs;
}

sub check_prereq {
    my $self = shift;

    my $info = $self->_enum_prereqs;
    return 1 unless $info;

    my $log_text = "Checking prerequisites...\n";

    my $failures = $self->prereq_failures($info);

    if ($failures) {
        $self->log_warn($log_text);
        for my $type ( @{ $self->prereq_action_types } ) {
            my $prereqs = $failures->{$type};
            $self->log_warn("  ${type}:\n") if keys %$prereqs;
            for my $module ( sort keys %$prereqs ) {
                my $status = $prereqs->{$module};
                my $prefix = ( $type =~ /^(?:\w+_)?recommends$/ ) ? "* " : "! ";
                $self->log_warn("    $prefix $status->{message}\n");
            }
        }
        return 0;
    }
    else {
        $self->log_verbose( $log_text . "Looks good\n\n" );
        return 1;
    }
}

sub perl_version {
    my ($self) = @_;
    return $^V ? $self->perl_version_to_float( sprintf "%vd", $^V ) : $];
}

sub perl_version_to_float {
    my ( $self, $version ) = @_;
    return $version if grep( /\./, $version ) < 2;
    $version =~ s/\./../;
    $version =~ s/\.(\d+)/sprintf '%03d', $1/eg;
    return $version;
}

sub _parse_conditions {
    my ( $self, $spec ) = @_;

    if ( $spec =~ /^\s*([\w.]+)\s*$/ ) { return (">= $spec");
    }
    else {
        return split /\s*,\s*/, $spec;
    }
}

sub try_require {
    my ( $self, $modname, $spec ) = @_;
    my $status =
      $self->check_installed_status( $modname, defined($spec) ? $spec : 0 );
    return unless $status->{ok};
    my $path = $modname;
    $path =~ s{::}{/}g;
    $path .= ".pm";
    if ( defined $INC{$path} ) {
        return 1;
    }
    elsif ( exists $INC{$path} ) { return;
    }
    else {
        return eval "require $modname";
    }
}

sub check_installed_status {
    my ( $self, $modname, $spec ) = @_;
    my %status = ( need => $spec );

    if ( $modname eq 'perl' ) {
        $status{have} = $self->perl_version;

    }
    elsif ( eval { no strict; $status{have} = ${"${modname}::VERSION"} } ) {

    }
    else {
        my $pm_info = Module::Build::ModuleInfo->new_from_module($modname);
        unless ( defined($pm_info) ) {
            @status{qw(have message)} =
              ( '<none>', "$modname is not installed" );
            return \%status;
        }

        $status{have} = eval { $pm_info->version() };
        if ( $spec and !defined( $status{have} ) ) {
            @status{qw(have message)} =
              ( undef, "Couldn't find a \$VERSION in prerequisite $modname" );
            return \%status;
        }
    }

    my @conditions = $self->_parse_conditions($spec);

    foreach (@conditions) {
        my ( $op, $version ) = /^\s*  (<=?|>=?|==|!=)  \s*  ([\w.]+)  \s*$/x
          or die "Invalid prerequisite condition '$_' for $modname";

        $version = $self->perl_version_to_float($version)
          if $modname eq 'perl';

        next if $op eq '>=' and !$version;

        unless ( $self->compare_versions( $status{have}, $op, $version ) ) {
            $status{message} =
"$modname ($status{have}) is installed, but we need version $op $version";
            return \%status;
        }
    }

    $status{ok} = 1;
    return \%status;
}

sub compare_versions {
    my $self = shift;
    my ( $v1, $op, $v2 ) = @_;
    $v1 = Module::Build::Version->new($v1)
      unless UNIVERSAL::isa( $v1, 'Module::Build::Version' );

    my $eval_str = "\$v1 $op \$v2";
    my $result   = eval $eval_str;
    $self->log_warn("error comparing versions: '$eval_str' $@") if $@;

    return $result;
}

sub check_installed_version {
    my ( $self, $modname, $spec ) = @_;

    my $status = $self->check_installed_status( $modname, $spec );

    if ( $status->{ok} ) {
        return $status->{have}
          if $status->{have} and "$status->{have}" ne '<none>';
        return '0 but true';
    }

    $@ = $status->{message};
    return 0;
}

sub make_executable {

    my $self = shift;
    foreach (@_) {
        my $current_mode = ( stat $_ )[2];
        chmod $current_mode | oct(111), $_;
    }
}

sub is_executable {
    my ( $self, $file ) = @_;
    return -x $file;
}

sub _startperl { shift()->config('startperl') }

sub _added_to_INC {
    my $self = shift;

    my %seen;
    $seen{$_}++ foreach $self->_default_INC;
    return grep !$seen{$_}++, @INC;
}

{
    my @default_inc;

    sub _default_INC {
        my $self = shift;
        return @default_inc if @default_inc;

        local $ENV{PERL5LIB};

        my $perl = ref($self) ? $self->perl : $self->find_perl_interpreter;

        my @inc = $self->_backticks( $perl, '-le', 'print for @INC' );
        chomp @inc;

        return @default_inc = @inc;
    }
}

sub print_build_script {
    my ( $self, $fh ) = @_;

    my $build_package = $self->build_class;

    my $closedata = "";

    my $config_requires;
    if ( -f $self->metafile ) {
        my $meta = eval { $self->read_metafile( $self->metafile ) };
        $config_requires =
          $meta && $meta->{configure_requires}{'Module::Build'};
    }
    $config_requires ||= 0;

    my %q = map { $_, $self->$_() } qw(config_dir base_dir);

    $q{base_dir} = Win32::GetShortPathName( $q{base_dir} )
      if $self->is_windowsish;

    $q{magic_numfile} = $self->config_file('magicnum');

    my @myINC = $self->_added_to_INC;
    for ( @myINC, values %q ) {
        $_ = File::Spec->canonpath($_);
        s/([\\\'])/\\$1/g;
    }

    my $quoted_INC   = join ",\n", map "     '$_'", @myINC;
    my $shebang      = $self->_startperl;
    my $magic_number = $self->magic_number;

    print $fh <<EOF;
$shebang

use strict;
use Cwd;
use File::Basename;
use File::Spec;

sub magic_number_matches {
  return 0 unless -e '$q{magic_numfile}';
  local *FH;
  open FH, '$q{magic_numfile}' or return 0;
  my \$filenum = <FH>;
  close FH;
  return \$filenum == $magic_number;
}

my \$progname;
my \$orig_dir;
BEGIN {
  \$^W = 1;  # Use warnings
  \$progname = basename(\$0);
  \$orig_dir = Cwd::cwd();
  my \$base_dir = '$q{base_dir}';
  if (!magic_number_matches()) {
    unless (chdir(\$base_dir)) {
      die ("Couldn't chdir(\$base_dir), aborting\\n");
    }
    unless (magic_number_matches()) {
      die ("Configuration seems to be out of date, please re-run 'perl Build.PL' again.\\n");
    }
  }
  unshift \@INC,
    (
$quoted_INC
    );
}

close(*DATA) unless eof(*DATA); # ensure no open handles to this script

use $build_package;
Module::Build->VERSION(q{$config_requires});

# Some platforms have problems setting \$^X in shebang contexts, fix it up here
\$^X = Module::Build->find_perl_interpreter;

if (-e 'Build.PL' and not $build_package->up_to_date('Build.PL', \$progname)) {
   warn "Warning: Build.PL has been altered.  You may need to run 'perl Build.PL' again.\\n";
}

# This should have just enough arguments to be able to bootstrap the rest.
my \$build = $build_package->resume (
  properties => {
    config_dir => '$q{config_dir}',
    orig_dir => \$orig_dir,
  },
);

\$build->dispatch;
EOF
}

sub create_mymeta {
    my ($self) = @_;

    my ( $meta_obj, $mymeta );
    my @metafiles   = ( $self->metafile,   $self->metafile2 );
    my @mymetafiles = ( $self->mymetafile, $self->mymetafile2 );

    for my $f (@mymetafiles) {
        if ( $self->delete_filetree($f) ) {
            $self->log_verbose("Removed previous '$f'\n");
        }
    }

    if ( $self->try_require( "CPAN::Meta", "2.110420" ) ) {
        for my $file (@metafiles) {
            next unless -f $file;
            $meta_obj = eval { CPAN::Meta->load_file($file) };
            last if $meta_obj;
        }
    }

    $mymeta = $meta_obj->as_struct
      if $meta_obj;

    if ( defined $mymeta ) {
        my $prereqs = $self->_normalize_prereqs;
        $mymeta->{prereqs}{runtime}{requires}   = $prereqs->{requires};
        $mymeta->{prereqs}{build}{requires}     = $prereqs->{build_requires};
        $mymeta->{prereqs}{runtime}{recommends} = $prereqs->{recommends};
        $mymeta->{prereqs}{runtime}{conflicts}  = $prereqs->{conflicts};
        for my $phase ( keys %{ $mymeta->{prereqs} } ) {
            if ( ref $mymeta->{prereqs}{$phase} eq 'HASH' ) {
                for my $type ( keys %{ $mymeta->{prereqs}{$phase} } ) {
                    if (   !defined $mymeta->{prereqs}{$phase}{$type}
                        || !keys %{ $mymeta->{prereqs}{$phase}{$type} } )
                    {
                        delete $mymeta->{prereqs}{$phase}{$type};
                    }
                }
            }
            if (   !defined $mymeta->{prereqs}{$phase}
                || !keys %{ $mymeta->{prereqs}{$phase} } )
            {
                delete $mymeta->{prereqs}{$phase};
            }
        }
        $mymeta->{dynamic_config} = 0;
        $mymeta->{generated_by} =
          "Module::Build version $Module::Build::VERSION";
        eval {
            $meta_obj = CPAN::Meta->new( $mymeta, { lazy_validation => 1 } );
        };
    }
    else {
        $meta_obj = $self->_get_meta_object(
            quiet   => 0,
            dynamic => 0,
            fatal   => 0,
            auto    => 0
        );
    }

    my @created = $self->_write_meta_files( $meta_obj, 'MYMETA' );

    $self->log_warn("Could not create MYMETA files\n")
      unless @created;

    return 1;
}

sub create_build_script {
    my ($self) = @_;

    $self->write_config;
    $self->create_mymeta;

    my ( $build_script, $dist_name, $dist_version ) = map $self->$_(),
      qw(build_script dist_name dist_version);

    if ( $self->delete_filetree($build_script) ) {
        $self->log_verbose("Removed previous script '$build_script'\n");
    }

    $self->log_info(
        "Creating new '$build_script' script for ",
        "'$dist_name' version '$dist_version'\n"
    );
    my $fh = IO::File->new(">$build_script")
      or die "Can't create '$build_script': $!";
    $self->print_build_script($fh);
    close $fh;

    $self->make_executable($build_script);

    return 1;
}

sub check_manifest {
    my $self = shift;
    return unless -e 'MANIFEST';

    require ExtUtils::Manifest;
    local ( $^W, $ExtUtils::Manifest::Quiet ) = ( 0, 1 );

    $self->log_verbose("Checking whether your kit is complete...\n");
    if ( my @missed = ExtUtils::Manifest::manicheck() ) {
        $self->log_warn(
            "WARNING: the following files are missing in your kit:\n",
            "\t", join( "\n\t", @missed ),
            "\n", "Please inform the author.\n\n"
        );
    }
    else {
        $self->log_verbose("Looks good\n\n");
    }
}

sub dispatch {
    my $self = shift;
    local $self->{_completed_actions} = {};

    if (@_) {
        my ( $action, %p ) = @_;
        my $args = $p{args} ? delete( $p{args} ) : {};

        local $self->{invoked_action} = $action;
        local $self->{args}           = { %{ $self->{args} }, %$args };
        local $self->{properties}     = { %{ $self->{properties} }, %p };
        return $self->_call_action($action);
    }

    die "No build action specified" unless $self->{action};
    local $self->{invoked_action} = $self->{action};
    $self->_call_action( $self->{action} );
}

sub _call_action {
    my ( $self, $action ) = @_;

    return if $self->{_completed_actions}{$action}++;

    local $self->{action} = $action;
    my $method = $self->can_action($action);
    die "No action '$action' defined, try running the 'help' action.\n"
      unless $method;
    $self->log_debug("Starting ACTION_$action\n");
    my $rc = $self->$method();
    $self->log_debug("Finished ACTION_$action\n");
    return $rc;
}

sub can_action {
    my ( $self, $action ) = @_;
    return $self->can("ACTION_$action");
}

sub cull_options {
    my $self = shift;
    my (@argv) = @_;

    return ( {}, @argv ) unless ( ref($self) );

    my $specs = $self->get_options;
    return ( {}, @argv ) unless ( $specs and %$specs );

    require Getopt::Long;
    my @specs;
    my $args = {};
    while ( my ( $k, $v ) = each %$specs ) {
        die "Option specification '$k' conflicts with a "
          . ref $self
          . " option of the same name"
          if $self->valid_property($k);
        push @specs, $k . ( defined $v->{type} ? $v->{type} : '' );
        push @specs, $v->{store} if exists $v->{store};
        $args->{$k} = $v->{default} if exists $v->{default};
    }

    local @ARGV = @argv;

    if (@specs) {
        Getopt::Long::Configure('pass_through');
        Getopt::Long::GetOptions( $args, @specs );
    }

    return $args, @ARGV;
}

sub unparse_args {
    my ( $self, $args ) = @_;
    my @out;
    while ( my ( $k, $v ) = each %$args ) {
        push @out,
          (
            UNIVERSAL::isa( $v, 'HASH' ) ? map { +"--$k", "$_=$v->{$_}" }
              keys %$v
            : UNIVERSAL::isa( $v, 'ARRAY' ) ? map { +"--$k", $_ } @$v
            : ( "--$k", $v )
          );
    }
    return @out;
}

sub args {
    my $self = shift;
    return wantarray ? %{ $self->{args} } : $self->{args} unless @_;
    my $key = shift;
    $self->{args}{$key} = shift if @_;
    return $self->{args}{$key};
}

sub _translate_option {
    my $self = shift;
    my $opt  = shift;

    ( my $tr_opt = $opt ) =~ tr/-/_/;

    return $tr_opt if grep $tr_opt =~ /^(?:no_?)?$_$/, qw(
      create_license
      create_makefile_pl
      create_readme
      extra_compiler_flags
      extra_linker_flags
      install_base
      install_path
      meta_add
      meta_merge
      test_files
      use_rcfile
      use_tap_harness
      tap_harness_args
      cpan_client
    );

    return $opt;
}

sub _read_arg {
    my ( $self, $args, $key, $val ) = @_;

    $key = $self->_translate_option($key);

    if ( exists $args->{$key} ) {
        $args->{$key} = [ $args->{$key} ] unless ref $args->{$key};
        push @{ $args->{$key} }, $val;
    }
    else {
        $args->{$key} = $val;
    }
}

sub _optional_arg {
    my $self = shift;
    my $opt  = shift;
    my $argv = shift;

    $opt = $self->_translate_option($opt);

    my @bool_opts = qw(
      build_bat
      create_license
      create_readme
      pollute
      quiet
      uninst
      use_rcfile
      verbose
      debug
      sign
      use_tap_harness
    );

    if ( grep $opt =~ /^no[-_]?$_$/, @bool_opts ) {
        $opt =~ s/^no-?//;
        return ( $opt, 0 );
    }

    return ( $opt, shift(@$argv) ) unless grep $_ eq $opt, @bool_opts;

    my $arg = 1;
    $arg = shift(@$argv) if @$argv && $argv->[0] =~ /^\d+$/;

    return ( $opt, $arg );
}

sub read_args {
    my $self = shift;

    ( my $args, @_ ) = $self->cull_options(@_);
    my %args = %$args;

    my $opt_re = qr/[\w\-]+/;

    my ( $action, @argv );
    while (@_) {
        local $_ = shift;
        if (/^(?:--)?($opt_re)=(.*)$/) {
            $self->_read_arg( \%args, $1, $2 );
        }
        elsif (/^--($opt_re)$/) {
            my ( $opt, $arg ) = $self->_optional_arg( $1, \@_ );
            $self->_read_arg( \%args, $opt, $arg );
        }
        elsif ( /^($opt_re)$/ and !defined($action) ) {
            $action = $1;
        }
        else {
            push @argv, $_;
        }
    }
    $args{ARGV} = \@argv;

    for ( 'extra_compiler_flags', 'extra_linker_flags' ) {
        $args{$_} = [ $self->split_like_shell( $args{$_} ) ]
          if exists $args{$_};
    }

    for ('include_dirs') {
        $args{$_} = [ $args{$_} ] if exists $args{$_} && !ref $args{$_};
    }

    for ( $self->hash_properties, 'config' ) {
        next unless exists $args{$_};
        my %hash;
        $args{$_} ||= [];
        $args{$_} = [ $args{$_} ] unless ref $args{$_};
        foreach my $arg ( @{ $args{$_} } ) {
            $arg =~ /($opt_re)=(.*)/
              or die
"Malformed '$_' argument: '$arg' should be something like 'foo=bar'";
            $hash{$1} = $2;
        }
        $args{$_} = \%hash;
    }

    for my $key (qw(prefix install_base destdir)) {
        next if !defined $args{$key};
        $args{$key} = $self->_detildefy( $args{$key} );
    }

    for my $key (qw(install_path)) {
        next if !defined $args{$key};

        for my $subkey ( keys %{ $args{$key} } ) {
            next if !defined $args{$key}{$subkey};
            my $subkey_ext = $self->_detildefy( $args{$key}{$subkey} );
            if ( $subkey eq 'html' ) { $args{$key}{binhtml} = $subkey_ext;
                $args{$key}{libhtml} = $subkey_ext;
            }
            else {
                $args{$key}{$subkey} = $subkey_ext;
            }
        }
    }

    if ( $args{makefile_env_macros} ) {
        require Module::Build::Compat;
        %args = ( %args, Module::Build::Compat->makefile_to_build_macros );
    }

    return \%args, $action;
}

sub _detildefy { }

sub _merge_arglist {
    my ( $self, $opts1, $opts2 ) = @_;

    $opts1 ||= {};
    $opts2 ||= {};
    my %new_opts = %$opts1;
    while ( my ( $key, $val ) = each %$opts2 ) {
        if ( exists( $opts1->{$key} ) ) {
            if ( ref($val) eq 'HASH' ) {
                while ( my ( $k, $v ) = each %$val ) {
                    $new_opts{$key}{$k} = $v
                      unless exists( $opts1->{$key}{$k} );
                }
            }
        }
        else {
            $new_opts{$key} = $val;
        }
    }

    return %new_opts;
}

sub _home_dir {
    my @home_dirs;
    push( @home_dirs, $ENV{HOME} ) if $ENV{HOME};

    push( @home_dirs,
        File::Spec->catpath( $ENV{HOMEDRIVE}, $ENV{HOMEPATH}, '' ) )
      if $ENV{HOMEDRIVE} && $ENV{HOMEPATH};

    my @other_home_envs = qw( USERPROFILE APPDATA WINDIR SYS$LOGIN );
    push( @home_dirs, map $ENV{$_}, grep $ENV{$_}, @other_home_envs );

    my @real_home_dirs = grep -d, @home_dirs;

    return wantarray ? @real_home_dirs : shift(@real_home_dirs);
}

sub _find_user_config {
    my $self = shift;
    my $file = shift;
    foreach my $dir ( $self->_home_dir ) {
        my $path = File::Spec->catfile( $dir, $file );
        return $path if -e $path;
    }
    return undef;
}

sub read_modulebuildrc {
    my ( $self, $action ) = @_;

    return () unless $self->use_rcfile;

    my $modulebuildrc;
    if ( exists( $ENV{MODULEBUILDRC} ) && $ENV{MODULEBUILDRC} eq 'NONE' ) {
        return ();
    }
    elsif ( exists( $ENV{MODULEBUILDRC} ) && -e $ENV{MODULEBUILDRC} ) {
        $modulebuildrc = $ENV{MODULEBUILDRC};
    }
    elsif ( exists( $ENV{MODULEBUILDRC} ) ) {
        $self->log_warn( "WARNING: Can't find resource file "
              . "'$ENV{MODULEBUILDRC}' defined in environment.\n"
              . "No options loaded\n" );
        return ();
    }
    else {
        $modulebuildrc = $self->_find_user_config('.modulebuildrc');
        return () unless $modulebuildrc;
    }

    my $fh = IO::File->new($modulebuildrc)
      or die "Can't open $modulebuildrc: $!";

    my %options;
    my $buffer = '';
    while ( defined( my $line = <$fh> ) ) {
        chomp($line);
        $line =~ s/#.*$//;
        next unless length($line);

        if ( $line =~ /^\S/ ) {
            if ($buffer) {
                my ( $action, $options ) = split( /\s+/, $buffer, 2 );
                $options{$action} .= $options . ' ';
                $buffer = '';
            }
            $buffer = $line;
        }
        else {
            $buffer .= $line;
        }
    }

    if ($buffer) { my ( $action, $options ) = split( /\s+/, $buffer, 2 );
        $options{$action} .= $options . ' ';
    }

    my ($global_opts) =
      $self->read_args( $self->split_like_shell( $options{'*'} || '' ) );

    if ( $action eq 'fakeinstall' && !exists $options{fakeinstall} ) {
        $action = 'install';
    }
    my ($action_opts) =
      $self->read_args( $self->split_like_shell( $options{$action} || '' ) );

    return $self->_merge_arglist( $action_opts, $global_opts );
}

sub merge_modulebuildrc {
    my ( $self, $action, %cmdline_opts ) = @_;
    my %rc_opts =
      $self->read_modulebuildrc( $action || $self->{action} || 'build' );
    my %new_opts = $self->_merge_arglist( \%cmdline_opts, \%rc_opts );
    $self->merge_args( $action, %new_opts );
}

sub merge_args {
    my ( $self, $action, %args ) = @_;
    $self->{action} = $action if defined $action;

    my %additive = map { $_ => 1 } $self->hash_properties;

    while ( my ( $key, $val ) = each %args ) {
        $self->{phash}{runtime_params}->access( $key => $val )
          if $self->valid_property($key);

        if ( $key eq 'config' ) {
            $self->config( $_ => $val->{$_} ) foreach keys %$val;
        }
        else {
            my $add_to =
                $additive{$key}             ? $self->{properties}{$key}
              : $self->valid_property($key) ? $self->{properties}
              :                               $self->{args};

            if ( $additive{$key} ) {
                $add_to->{$_} = $val->{$_} foreach keys %$val;
            }
            else {
                $add_to->{$key} = $val;
            }
        }
    }
}

sub cull_args {
    my $self     = shift;
    my @arg_list = @_;
    unshift @arg_list, $self->split_like_shell( $ENV{PERL_MB_OPT} )
      if $ENV{PERL_MB_OPT};
    my ( $args, $action ) = $self->read_args(@arg_list);
    $self->merge_args( $action, %$args );
    $self->merge_modulebuildrc( $action, %$args );
}

sub super_classes {
    my ( $self, $class, $seen ) = @_;
    $class ||= ref($self) || $self;
    $seen ||= {};

    no strict 'refs';
    my @super = grep { not $seen->{$_}++ } $class, @{ $class . '::ISA' };
    return @super, map { $self->super_classes( $_, $seen ) } @super;
}

sub known_actions {
    my ($self) = @_;

    my %actions;
    no strict 'refs';

    foreach my $class ( $self->super_classes ) {
        foreach ( keys %{ $class . '::' } ) {
            $actions{$1}++ if /^ACTION_(\w+)/;
        }
    }

    return wantarray ? sort keys %actions : \%actions;
}

sub get_action_docs {
    my ( $self, $action ) = @_;
    my $actions = $self->known_actions;
    die "No known action '$action'" unless $actions->{$action};

    my ( $files_found, @docs ) = (0);
    foreach my $class ( $self->super_classes ) {
        ( my $file = $class ) =~ s{::}{/}g;
        $file = $INC{ $file . '.pm' } or next;
        my $fh = IO::File->new("< $file") or next;
        $files_found++;

        local $_;
        while (<$fh>) {
            last if /^=head1 ACTIONS\s/;
        }

        my $style;
        while (<$fh>) {
            last if /^=head1 /;

            if (/^=(item|head2)\s+\Q$action\E\b/) {
                $style = $1;
                push @docs, $_;
                last;
            }
        }
        $style or next;

        if ( $style eq 'item' ) {
            my ( $found, $inlist ) = ( 0, 0 );
            while (<$fh>) {
                if (/^=(item|back)/) {
                    last unless $inlist;
                }
                push @docs, $_;
                ++$inlist if /^=over/;
                --$inlist if /^=back/;
            }
        }
        else {  while (<$fh>) {
                last if (/^=(?:head[12]|cut)/);
                push @docs, $_;
            }
        }
    }

    unless ($files_found) {
        $@ = "Couldn't find any documentation to search";
        return;
    }
    unless (@docs) {
        $@ = "Couldn't find any docs for action '$action'";
        return;
    }

    return join '', @docs;
}

sub ACTION_prereq_report {
    my $self = shift;
    $self->log_info( $self->prereq_report );
}

sub ACTION_prereq_data {
    my $self = shift;
    $self->log_info( Module::Build::Dumper->_data_dump( $self->prereq_data ) );
}

sub prereq_data {
    my $self  = shift;
    my @types = ( 'configure_requires', @{ $self->prereq_action_types } );
    my $info  = { map { $_ => $self->$_() } grep { %{ $self->$_() } } @types };
    return $info;
}

sub prereq_report {
    my $self = shift;
    my $info = $self->prereq_data;

    my $output = '';
    foreach my $type ( keys %$info ) {
        my $prereqs = $info->{$type};
        $output .= "\n$type:\n";
        my $mod_len = 2;
        my $ver_len = 4;
        my %mods;
        while ( my ( $modname, $spec ) = each %$prereqs ) {
            my $len = length $modname;
            $mod_len = $len if $len > $mod_len;
            $spec ||= '0';
            $len = length $spec;
            $ver_len = $len if $len > $ver_len;

            my $mod = $self->check_installed_status( $modname, $spec );
            $mod->{name} = $modname;
            $mod->{ok} ||= 0;
            $mod->{ok} = !$mod->{ok} if $type =~ /^(\w+_)?conflicts$/;

            $mods{ lc $modname } = $mod;
        }

        my $space  = q{ } x ( $mod_len - 3 );
        my $vspace = q{ } x ( $ver_len - 3 );
        my $sline  = q{-} x ( $mod_len - 3 );
        my $vline  = q{-} x ( $ver_len - 3 );
        my $disposition = ( $type =~ /^(\w+_)?conflicts$/ ) ? 'Clash' : 'Need';
        $output .=
            "    Module $space  $disposition $vspace  Have\n"
          . "    ------$sline+------$vline-+----------\n";

        for my $k ( sort keys %mods ) {
            my $mod    = $mods{$k};
            my $space  = q{ } x ( $mod_len - length $k );
            my $vspace = q{ } x ( $ver_len - length $mod->{need} );
            my $f      = $mod->{ok} ? ' ' : '!';
            $output .=
              "  $f $mod->{name} $space     $mod->{need}  $vspace   "
              . ( defined( $mod->{have} ) ? $mod->{have} : "" ) . "\n";
        }
    }
    return $output;
}

sub ACTION_help {
    my ($self) = @_;
    my $actions = $self->known_actions;

    if ( @{ $self->{args}{ARGV} } ) {
        my $msg =
          eval { $self->get_action_docs( $self->{args}{ARGV}[0], $actions ) };
        print $@ ? "$@\n" : $msg;
        return;
    }

    print <<EOF;

 Usage: $0 <action> arg1=value arg2=value ...
 Example: $0 test verbose=1

 Actions defined:
EOF

    print $self->_action_listing($actions);

    print "\nRun `Build help <action>` for details on an individual action.\n";
    print "See `perldoc Module::Build` for complete documentation.\n";
}

sub _action_listing {
    my ( $self, $actions ) = @_;

    my @actions = sort keys %$actions;
    @actions = map $actions[ ( $_ + ( $_ % 2 ) * @actions ) / 2 ],
      0 .. $#actions;

    my $out = '';
    while ( my ( $one, $two ) = splice @actions, 0, 2 ) {
        $out .=
          sprintf( "  %-12s                   %-12s\n", $one, $two || '' );
    }
    $out =~ s{\s*$}{}mg;
    return $out;
}

sub ACTION_retest {
    my ($self) = @_;

    local @INC = @INC;

    @INC = grep { ref() || -d } @INC if @INC > 100;

    $self->do_tests;
}

sub ACTION_testall {
    my ($self) = @_;

    my @types;
    for my $action ( grep { $_ ne 'all' } $self->get_test_types ) {
        push( @types, $action );
    }
    $self->generic_test( types => [ 'default', @types ] );
}

sub get_test_types {
    my ($self) = @_;

    my $t = $self->{properties}->{test_types};
    return ( defined $t ? ( keys %$t ) : () );
}

sub ACTION_test {
    my ($self) = @_;
    $self->generic_test( type => 'default' );
}

sub generic_test {
    my $self = shift;
    ( @_ % 2 ) and croak('Odd number of elements in argument hash');
    my %args = @_;

    my $p = $self->{properties};

    my @types = (
        ( exists( $args{type} )  ? $args{type}       : () ),
        ( exists( $args{types} ) ? @{ $args{types} } : () ),
    );
    @types or croak "need some types of tests to check";

    my %test_types = (
        default => $p->{test_file_exts},
        ( defined( $p->{test_types} ) ? %{ $p->{test_types} } : () ),
    );

    for my $type (@types) {
        croak "$type not defined in test_types!"
          unless defined $test_types{$type};
    }

    local $p->{test_file_exts} =
      [ map { ref $_ ? @$_ : $_ } @test_types{@types} ];
    $self->depends_on('code');

    local @INC = @INC;

    unshift @INC,
      (
        File::Spec->catdir( $p->{base_dir}, $self->blib, 'lib' ),
        File::Spec->catdir( $p->{base_dir}, $self->blib, 'arch' )
      );

    @INC = grep { ref() || -d } @INC if @INC > 100;

    $self->do_tests;
}

sub do_tests {
    my $self = shift;

    my $tests = $self->find_test_files;

    local $ENV{PERL_DL_NONLAZY} = 1;

    if (@$tests) {
        my $args = $self->tap_harness_args;
        if ( $self->use_tap_harness or ( $args and %$args ) ) {
            my $aggregate = $self->run_tap_harness($tests);
            if ( $aggregate->has_errors ) {
                die "Errors in testing.  Cannot continue.\n";
            }
        }
        else {
            $self->run_test_harness($tests);
        }
    }
    else {
        $self->log_info("No tests defined.\n");
    }

    $self->run_visual_script;
}

sub run_tap_harness {
    my ( $self, $tests ) = @_;

    require TAP::Harness;

    my $aggregate = TAP::Harness->new(
        {
            lib       => [@INC],
            verbosity => $self->{properties}{verbose},
            switches  => [ $self->harness_switches ],
            %{ $self->tap_harness_args },
        }
    )->runtests(@$tests);

    return $aggregate;
}

sub run_test_harness {
    my ( $self, $tests ) = @_;
    require Test::Harness;
    my $p                = $self->{properties};
    my @harness_switches = $self->harness_switches;

    local $^X = $self->perl;

    local $Test::Harness::switches = join ' ', grep defined,
      $Test::Harness::switches, @harness_switches;
    local $Test::Harness::Switches = join ' ', grep defined,
      $Test::Harness::Switches, @harness_switches;
    local $ENV{HARNESS_PERL_SWITCHES} = join ' ', grep defined,
      $ENV{HARNESS_PERL_SWITCHES}, @harness_switches;

    $Test::Harness::switches = undef unless length $Test::Harness::switches;
    $Test::Harness::Switches = undef unless length $Test::Harness::Switches;
    delete $ENV{HARNESS_PERL_SWITCHES}
      unless length $ENV{HARNESS_PERL_SWITCHES};

    local (
        $Test::Harness::verbose, $Test::Harness::Verbose,
        $ENV{TEST_VERBOSE},      $ENV{HARNESS_VERBOSE}
    ) = ( $p->{verbose} || 0 ) x 4;

    Test::Harness::runtests(@$tests);
}

sub run_visual_script {
    my $self = shift;
    $self->run_perl_script( 'visual.pl', '-Mblib=' . $self->blib )
      if -e 'visual.pl';
}

sub harness_switches {
    shift->{properties}{debugger} ? qw(-w -d) : ();
}

sub test_files {
    my $self = shift;
    my $p    = $self->{properties};
    if (@_) {
        return $p->{test_files} = ( @_ == 1 ? shift : [@_] );
    }
    return $self->find_test_files;
}

sub expand_test_dir {
    my ( $self, $dir ) = @_;
    my $exts = $self->{properties}{test_file_exts};

    return
      sort map { @{ $self->rscan_dir( $dir, qr{^[^.].*\Q$_\E$} ) } } @$exts
      if $self->recursive_test_files;

    return sort map { glob File::Spec->catfile( $dir, "*$_" ) } @$exts;
}

sub ACTION_testdb {
    my ($self) = @_;
    local $self->{properties}{debugger} = 1;
    $self->depends_on('test');
}

sub ACTION_testcover {
    my ($self) = @_;

    unless ( Module::Build::ModuleInfo->find_module_by_name('Devel::Cover') ) {
        warn("Cannot run testcover action unless Devel::Cover is installed.\n");
        return;
    }

    $self->add_to_cleanup( 'coverage', 'cover_db' );
    $self->depends_on('code');

    if ( -e 'cover_db' ) {
        my $pm_files =
          $self->rscan_dir( File::Spec->catdir( $self->blib, 'lib' ),
            $self->file_qr('\.pm$') );
        my $cover_files =
          $self->rscan_dir( 'cover_db', sub { -f $_ and not /\.html$/ } );

        $self->do_system(qw(cover -delete))
          unless $self->up_to_date( $pm_files, $cover_files )
          && $self->up_to_date( $self->test_files, $cover_files );
    }

    local $Test::Harness::switches = local $Test::Harness::Switches =
      local $ENV{HARNESS_PERL_SWITCHES} = "-MDevel::Cover";

    $self->depends_on('test');
    $self->do_system('cover');
}

sub ACTION_code {
    my ($self) = @_;

    my $blib = $self->blib;
    $self->add_to_cleanup($blib);
    File::Path::mkpath( File::Spec->catdir( $blib, 'arch' ) );

    if ( my $split = $self->autosplit ) {
        $self->autosplit_file( $_, $blib ) for ref($split) ? @$split : ($split);
    }

    foreach my $element ( @{ $self->build_elements } ) {
        my $method = "process_${element}_files";
        $method = "process_files_by_extension" unless $self->can($method);
        $self->$method($element);
    }

    $self->depends_on('config_data');
}

sub ACTION_build {
    my $self = shift;
    $self->log_info( "Building " . $self->dist_name . "\n" );
    $self->depends_on('code');
    $self->depends_on('docs');
}

sub process_files_by_extension {
    my ( $self, $ext ) = @_;

    my $method = "find_${ext}_files";
    my $files =
        $self->can($method)
      ? $self->$method()
      : $self->_find_file_by_type( $ext, 'lib' );

    while ( my ( $file, $dest ) = each %$files ) {
        $self->copy_if_modified(
            from => $file,
            to   => File::Spec->catfile( $self->blib, $dest )
        );
    }
}

sub process_support_files {
    my $self = shift;
    my $p    = $self->{properties};
    return unless $p->{c_source};

    my $files;
    if ( ref( $p->{c_source} ) eq "ARRAY" ) {
        push @{ $p->{include_dirs} }, @{ $p->{c_source} };
        for my $path ( @{ $p->{c_source} } ) {
            push @$files,
              @{
                $self->rscan_dir( $path,
                    $self->file_qr('\.c(c|p|pp|xx|\+\+)?$') )
              };
        }
    }
    else {
        push @{ $p->{include_dirs} }, $p->{c_source};
        $files =
          $self->rscan_dir( $p->{c_source},
            $self->file_qr('\.c(c|p|pp|xx|\+\+)?$') );
    }

    foreach my $file (@$files) {
        push @{ $p->{objects} }, $self->compile_c($file);
    }
}

sub process_share_dir_files {
    my $self  = shift;
    my $files = $self->_find_share_dir_files;
    return unless $files;

    my $share_prefix = File::Spec->catdir( $self->blib, qw/lib auto share/ );

    while ( my ( $file, $dest ) = each %$files ) {
        $self->copy_if_modified(
            from => $file,
            to   => File::Spec->catfile( $share_prefix, $dest )
        );
    }
}

sub _find_share_dir_files {
    my $self      = shift;
    my $share_dir = $self->share_dir;
    return unless $share_dir;

    my @file_map;
    if ( $share_dir->{dist} ) {
        my $prefix = "dist/" . $self->dist_name;
        push @file_map, $self->_share_dir_map( $prefix, $share_dir->{dist} );
    }

    if ( $share_dir->{module} ) {
        for my $mod ( keys %{ $share_dir->{module} } ) {
            ( my $altmod = $mod ) =~ s{::}{-}g;
            my $prefix = "module/$altmod";
            push @file_map,
              $self->_share_dir_map( $prefix, $share_dir->{module}{$mod} );
        }
    }

    return {@file_map};
}

sub _share_dir_map {
    my ( $self, $prefix, $list ) = @_;
    my %files;
    for my $dir (@$list) {
        for my $f ( @{ $self->rscan_dir( $dir, sub { -f } ) } ) {
            $f =~ s{\A.*?\Q$dir\E/}{};
            $files{"$dir/$f"} = "$prefix/$f";
        }
    }
    return %files;
}

sub process_PL_files {
    my ($self) = @_;
    my $files = $self->find_PL_files;

    while ( my ( $file, $to ) = each %$files ) {
        unless ( $self->up_to_date( $file, $to ) ) {
            $self->run_perl_script( $file, [], [@$to] ) or die "$file failed";
            $self->add_to_cleanup(@$to);
        }
    }
}

sub process_xs_files {
    my $self  = shift;
    my $files = $self->find_xs_files;
    while ( my ( $from, $to ) = each %$files ) {
        unless ( $from eq $to ) {
            $self->add_to_cleanup($to);
            $self->copy_if_modified( from => $from, to => $to );
        }
        $self->process_xs($to);
    }
}

sub process_pod_files { shift()->process_files_by_extension( shift() ) }
sub process_pm_files  { shift()->process_files_by_extension( shift() ) }

sub process_script_files {
    my $self  = shift;
    my $files = $self->find_script_files;
    return unless keys %$files;

    my $script_dir = File::Spec->catdir( $self->blib, 'script' );
    File::Path::mkpath($script_dir);

    foreach my $file ( keys %$files ) {
        my $result = $self->copy_if_modified( $file, $script_dir, 'flatten' )
          or next;
        $self->fix_shebang_line($result) unless $self->is_vmsish;
        $self->make_executable($result);
    }
}

sub find_PL_files {
    my $self = shift;
    if ( my $files = $self->{properties}{PL_files} ) {

        if ( UNIVERSAL::isa( $files, 'ARRAY' ) ) {
            return {
                map { $_, [/^(.*)\.PL$/] }
                map $self->localize_file_path($_), @$files
            };

        }
        elsif ( UNIVERSAL::isa( $files, 'HASH' ) ) {
            my %out;
            while ( my ( $file, $to ) = each %$files ) {
                $out{ $self->localize_file_path($file) } =
                  [ map $self->localize_file_path($_), ref $to ? @$to : ($to) ];
            }
            return \%out;

        }
        else {
            die "'PL_files' must be a hash reference or array reference";
        }
    }

    return unless -d 'lib';
    return { map { $_, [/^(.*)\.PL$/i] }
          @{ $self->rscan_dir( 'lib', $self->file_qr('\.PL$') ) } };
}

sub find_pm_files  { shift->_find_file_by_type( 'pm',  'lib' ) }
sub find_pod_files { shift->_find_file_by_type( 'pod', 'lib' ) }
sub find_xs_files  { shift->_find_file_by_type( 'xs',  'lib' ) }

sub find_script_files {
    my $self = shift;
    if ( my $files = $self->script_files ) {
        return { map { $self->localize_file_path($_), $files->{$_} }
              keys %$files };
    }

    return {};
}

sub find_test_files {
    my $self = shift;
    my $p    = $self->{properties};

    if ( my $files = $p->{test_files} ) {
        $files = [ keys %$files ] if UNIVERSAL::isa( $files, 'HASH' );
        $files = [
            map { -d $_ ? $self->expand_test_dir($_) : $_ }
              map glob,
            $self->split_like_shell($files)
        ];

        return [ map $self->localize_file_path($_), @$files ];

    }
    else {
        my @tests;
        push @tests, 'test.pl' if -e 'test.pl';
        push @tests, $self->expand_test_dir('t') if -e 't' and -d _;
        return \@tests;
    }
}

sub _find_file_by_type {
    my ( $self, $type, $dir ) = @_;

    if ( my $files = $self->{properties}{"${type}_files"} ) {
        return { map $self->localize_file_path($_), %$files };
    }

    return {} unless -d $dir;
    return {
        map { $_, $_ }
          map $self->localize_file_path($_),
        grep !/\.\#/,
        @{ $self->rscan_dir( $dir, $self->file_qr("\\.$type\$") ) }
    };
}

sub localize_file_path {
    my ( $self, $path ) = @_;
    return File::Spec->catfile( split m{/}, $path );
}

sub localize_dir_path {
    my ( $self, $path ) = @_;
    return File::Spec->catdir( split m{/}, $path );
}

sub fix_shebang_line { my ( $self, @files ) = @_;
    my $c = ref($self) ? $self->{config} : 'Module::Build::Config';

    my ($does_shbang) = $c->get('sharpbang') =~ /^\s*\#\!/;
    for my $file (@files) {
        my $FIXIN = IO::File->new($file) or die "Can't process '$file': $!";
        local $/ = "\n";
        chomp( my $line = <$FIXIN> );
        next unless $line =~ s/^\s*\#!\s*//;

        my ( $cmd, $arg ) = ( split( ' ', $line, 2 ), '' );
        next unless $cmd =~ /perl/i;
        my $interpreter = $self->{properties}{perl};

        $self->log_verbose("Changing sharpbang in $file to $interpreter\n");
        my $shb = '';
        $shb .= $c->get('sharpbang') . "$interpreter $arg\n" if $does_shbang;

        $shb .= qq{
eval 'exec $interpreter $arg -S \$0 \${1+"\$\@"}'
    if 0; # not running under some shell
} unless $self->is_windowsish;

        my $FIXOUT = IO::File->new(">$file.new")
          or die "Can't create new $file: $!\n";

        local $\;
        undef $/;
        print $FIXOUT $shb, <$FIXIN>;
        close $FIXIN;
        close $FIXOUT;

        rename( $file, "$file.bak" )
          or die "Can't rename $file to $file.bak: $!";

        rename( "$file.new", $file )
          or die "Can't rename $file.new to $file: $!";

        $self->delete_filetree("$file.bak")
          or $self->log_warn("Couldn't clean up $file.bak, leaving it there");

        $self->do_system( $c->get('eunicefix'), $file )
          if $c->get('eunicefix') ne ':';
    }
}

sub ACTION_testpod {
    my $self = shift;
    $self->depends_on('docs');

    eval q{use Test::Pod 0.95; 1}
      or die "The 'testpod' action requires Test::Pod version 0.95";

    my @files = sort keys %{ $self->_find_pods( $self->libdoc_dirs ) }, keys %{
        $self->_find_pods( $self->bindoc_dirs,
            exclude => [ $self->file_qr('\.bat$') ] )
      }
      or die "Couldn't find any POD files to test\n";

    {
        package Module::Build::PodTester;
        Test::Pod->import( tests => scalar @files );
        pod_file_ok($_) foreach @files;
    }
}

sub ACTION_testpodcoverage {
    my $self = shift;

    $self->depends_on('docs');

    eval q{use Test::Pod::Coverage 1.00; 1}
      or die "The 'testpodcoverage' action requires ",
      "Test::Pod::Coverage version 1.00";

    local @INC = @INC;
    my $p = $self->{properties};
    unshift( @INC, File::Spec->catdir( $p->{base_dir}, $self->blib, 'lib' ), );

    all_pod_coverage_ok();
}

sub ACTION_docs {
    my $self = shift;

    $self->depends_on('code');
    $self->depends_on( 'manpages', 'html' );
}

sub _is_default_installable {
    my $self = shift;
    my $type = shift;
    return (
        $self->install_destination($type) && ( $self->install_path($type)
            || $self->install_sets( $self->installdirs )->{$type} )
    ) ? 1 : 0;
}

sub _is_ActivePerl {
    my $self = shift;
    unless ( exists( $self->{_is_ActivePerl} ) ) {
        $self->{_is_ActivePerl} =
          ( eval { require ActivePerl::DocTools; } || 0 );
    }
    return $self->{_is_ActivePerl};
}

sub _is_ActivePPM {
    my $self = shift;
    unless ( exists( $self->{_is_ActivePPM} ) ) {
        $self->{_is_ActivePPM} = ( eval { require ActivePerl::PPM; } || 0 );
    }
    return $self->{_is_ActivePPM};
}

sub ACTION_manpages {
    my $self = shift;

    return unless $self->_mb_feature('manpage_support');

    $self->depends_on('code');

    foreach my $type (qw(bin lib)) {
        next
          unless ( $self->invoked_action eq 'manpages'
            || $self->_is_default_installable("${type}doc") );
        my $files = $self->_find_pods(
            $self->{properties}{"${type}doc_dirs"},
            exclude => [ $self->file_qr('\.bat$') ]
        );
        next unless %$files;

        my $sub = $self->can("manify_${type}_pods");
        $self->$sub() if defined($sub);
    }
}

sub manify_bin_pods {
    my $self = shift;

    my $files = $self->_find_pods(
        $self->{properties}{bindoc_dirs},
        exclude => [ $self->file_qr('\.bat$') ]
    );
    return unless keys %$files;

    my $mandir = File::Spec->catdir( $self->blib, 'bindoc' );
    File::Path::mkpath( $mandir, 0, oct(777) );

    require Pod::Man;
    foreach my $file ( keys %$files ) {
        my $parser = Pod::Man->new( section => 1 );
        my $manpage =
          $self->man1page_name($file) . '.' . $self->config('man1ext');
        my $outfile = File::Spec->catfile( $mandir, $manpage );
        next if $self->up_to_date( $file, $outfile );
        $self->log_verbose("Manifying $file -> $outfile\n");
        eval { $parser->parse_from_file( $file, $outfile ); 1 }
          or $self->log_warn("Error creating '$outfile': $@\n");
        $files->{$file} = $outfile;
    }
}

sub manify_lib_pods {
    my $self = shift;

    my $files = $self->_find_pods( $self->{properties}{libdoc_dirs} );
    return unless keys %$files;

    my $mandir = File::Spec->catdir( $self->blib, 'libdoc' );
    File::Path::mkpath( $mandir, 0, oct(777) );

    require Pod::Man;
    while ( my ( $file, $relfile ) = each %$files ) {
        my $parser = Pod::Man->new( section => 3 );
        my $manpage =
          $self->man3page_name($relfile) . '.' . $self->config('man3ext');
        my $outfile = File::Spec->catfile( $mandir, $manpage );
        next if $self->up_to_date( $file, $outfile );
        $self->log_verbose("Manifying $file -> $outfile\n");
        eval { $parser->parse_from_file( $file, $outfile ); 1 }
          or $self->log_warn("Error creating '$outfile': $@\n");
        $files->{$file} = $outfile;
    }
}

sub _find_pods {
    my ( $self, $dirs, %args ) = @_;
    my %files;
    foreach my $spec (@$dirs) {
        my $dir = $self->localize_dir_path($spec);
        next unless -e $dir;

      FILE: foreach my $file ( @{ $self->rscan_dir($dir) } ) {
            foreach my $regexp ( @{ $args{exclude} } ) {
                next FILE if $file =~ $regexp;
            }
            $files{$file} = File::Spec->abs2rel( $file, $dir )
              if $self->contains_pod($file);
        }
    }
    return \%files;
}

sub contains_pod {
    my ( $self, $file ) = @_;
    return '' unless -T $file;

    my $fh = IO::File->new($file) or die "Can't open $file: $!";
    while ( my $line = <$fh> ) {
        return 1 if $line =~ /^\=(?:head|pod|item)/;
    }

    return '';
}

sub ACTION_html {
    my $self = shift;

    return unless $self->_mb_feature('HTML_support');

    $self->depends_on('code');

    foreach my $type (qw(bin lib)) {
        next
          unless ( $self->invoked_action eq 'html'
            || $self->_is_default_installable("${type}html") );
        $self->htmlify_pods($type);
    }
}

sub htmlify_pods {
    my $self    = shift;
    my $type    = shift;
    my $htmldir = shift || File::Spec->catdir( $self->blib, "${type}html" );

    $self->add_to_cleanup('pod2htm*');

    my $pods = $self->_find_pods( $self->{properties}{"${type}doc_dirs"},
        exclude => [ $self->file_qr('\.(?:bat|com|html)$') ] );
    return unless %$pods;

    unless ( -d $htmldir ) {
        File::Path::mkpath( $htmldir, 0, oct(755) )
          or die "Couldn't mkdir $htmldir: $!";
    }

    my @rootdirs =
        ( $type eq 'bin' ) ? qw(bin)
      : $self->installdirs eq 'core' ? qw(lib)
      :                                qw(site lib);
    my $podroot =
      $ENV{PERL_CORE}
      ? File::Basename::dirname( $ENV{PERL_CORE} )
      : $self->original_prefix('core');

    my $htmlroot = $self->install_sets('core')->{libhtml};
    my @podpath  = (
        map { File::Spec->abs2rel( $_, $podroot ) } grep { -d } (
            $self->install_sets( 'core', 'lib' )
            , $self->install_sets( 'core', 'bin' )
            , $self->install_sets( 'site', 'lib' ), )
      ),
      File::Spec->rel2abs( $self->blib );

    my $podpath =
      $ENV{PERL_CORE}
      ? File::Spec->catdir( $podroot, 'lib' )
      : join( ":", map { tr,:\\,|/,; $_ } @podpath );

    my $blibdir = join(
        '/',
        File::Spec->splitdir(
            ( File::Spec->splitpath( File::Spec->rel2abs($htmldir), 1 ) )[1]
        ),
        ''
    );

    my ( $with_ActiveState, $htmltool );

    if ( $with_ActiveState = $self->_is_ActivePerl
        && eval { require ActivePerl::DocTools::Pod; 1 } )
    {
        my $tool_v = ActiveState::DocTools::Pod->VERSION;
        $htmltool = "ActiveState::DocTools::Pod";
        $htmltool .= " $tool_v" if $tool_v && length $tool_v;
    }
    else {
        require Module::Build::PodParser;
        require Pod::Html;
        $htmltool = "Pod::Html " . Pod::Html->VERSION;
    }
    $self->log_verbose("Converting Pod to HTML with $htmltool\n");

    my $errors = 0;

  POD:
    foreach my $pod ( keys %$pods ) {

        my ( $name, $path ) =
          File::Basename::fileparse( $pods->{$pod},
            $self->file_qr('\.(?:pm|plx?|pod)$') );
        my @dirs = File::Spec->splitdir( File::Spec->canonpath($path) );
        pop(@dirs) if scalar(@dirs) && $dirs[-1] eq File::Spec->curdir;

        my $fulldir = File::Spec->catdir( $htmldir, @rootdirs, @dirs );
        my $tmpfile = File::Spec->catfile( $fulldir, "${name}.tmp" );
        my $outfile = File::Spec->catfile( $fulldir, "${name}.html" );
        my $infile  = File::Spec->abs2rel($pod);

        next if $self->up_to_date( $infile, $outfile );

        unless ( -d $fulldir ) {
            File::Path::mkpath( $fulldir, 0, oct(755) )
              or die "Couldn't mkdir $fulldir: $!";
        }

        $self->log_verbose("HTMLifying $infile -> $outfile\n");
        if ($with_ActiveState) {
            my $depth = @rootdirs + @dirs;
            my %opts  = (
                infile  => $infile,
                outfile => $tmpfile,
                podpath => $podpath,
                podroot => $podroot,
                index   => 1,
                depth   => $depth,
            );
            eval {
                ActivePerl::DocTools::Pod::pod2html(%opts);
                1;
            }
              or $self->log_warn( "[$htmltool] pod2html ("
                  . join( ", ", map { "q{$_} => q{$opts{$_}}" } ( keys %opts ) )
                  . ") failed: $@" );
        }
        else {
            my $path2root = join( '/', ('..') x ( @rootdirs + @dirs ) );
            my $fh = IO::File->new($infile) or die "Can't read $infile: $!";
            my $abstract =
              Module::Build::PodParser->new( fh => $fh )->get_abstract();

            my $title = join( '::', ( @dirs, $name ) );
            $title .= " - $abstract" if $abstract;

            my @opts = (
                "--title=$title",     "--podpath=$podpath",
                "--infile=$infile",   "--outfile=$tmpfile",
                "--podroot=$podroot", "--htmlroot=$path2root",
            );

            unless ( eval { Pod::Html->VERSION(1.12) } ) {
                push( @opts, ('--flush') );
            }

            if ( eval { Pod::Html->VERSION(1.12) } ) {
                push( @opts, ( '--header', '--backlink' ) );
            }
            elsif ( eval { Pod::Html->VERSION(1.03) } ) {
                push( @opts, ( '--header', '--backlink=Back to Top' ) );
            }

            $self->log_verbose("P::H::pod2html @opts\n");
            {
                my $orig = Cwd::getcwd();
                eval { Pod::Html::pod2html(@opts); 1 }
                  or $self->log_warn( "[$htmltool] pod2html( "
                      . join( ", ", map { "q{$_}" } @opts )
                      . ") failed: $@" );
                chdir($orig);
            }
        }
        if ( !-r $tmpfile ) {
            $errors++;
            next POD;
        }
        my $fh = IO::File->new($tmpfile) or die "Can't read $tmpfile: $!";
        my $html = join( '', <$fh> );
        $fh->close;
        if ( !$self->_is_ActivePerl ) {
            $html =~
s#^<!DOCTYPE .*?>#<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN">#im;
            $html =~ s#<html xmlns="http://www.w3.org/1999/xhtml">#<html>#i;

            $html =~
s#<head>#<head>\n<!-- saved from url=(0017)http://localhost/ -->#i;
        }
        $html =~ s/\Q$blibdir\E//g;

        $fh = IO::File->new(">$outfile") or die "Can't write $outfile: $!";
        print $fh $html;
        $fh->close;
        unlink($tmpfile);
    }

    return !$errors;

}

sub man1page_name {
    my $self = shift;
    return File::Basename::basename(shift);
}

sub man3page_name {
    my $self = shift;
    my ( $vol, $dirs, $file ) = File::Spec->splitpath(shift);
    my @dirs = File::Spec->splitdir( File::Spec->canonpath($dirs) );

    $file =~ s/\.p(?:od|m|l)\z//i;

    return join( $self->manpage_separator, @dirs, $file );
}

sub manpage_separator {
    return '::';
}

sub ACTION_diff {
    my $self = shift;
    $self->depends_on('build');
    my $local_lib = File::Spec->rel2abs('lib');
    my @myINC = grep { $_ ne $local_lib } @INC;

    push @myINC, map $self->install_destination($_), qw(lib arch);

    my @flags = @{ $self->{args}{ARGV} };
    @flags = $self->split_like_shell( $self->{args}{flags} || '' )
      unless @flags;

    my $installmap = $self->install_map;
    delete $installmap->{read};
    delete $installmap->{write};

    my $text_suffix = $self->file_qr('\.(pm|pod)$');

    while ( my $localdir = each %$installmap ) {
        my @localparts = File::Spec->splitdir($localdir);
        my $files = $self->rscan_dir( $localdir, sub { -f } );

        foreach my $file (@$files) {
            my @parts = File::Spec->splitdir($file);
            @parts = @parts[ @localparts .. $#parts ];

            my $installed = Module::Build::ModuleInfo->find_module_by_name(
                join( '::', @parts ), \@myINC );
            if ( not $installed ) {
                print "Only in lib: $file\n";
                next;
            }

            my $status = File::Compare::compare( $installed, $file );
            next if $status == 0;
            die "Can't compare $installed and $file: $!" if $status == -1;

            if ( $file =~ $text_suffix ) {
                $self->do_system( 'diff', @flags, $installed, $file );
            }
            else {
                print "Binary files $file and $installed differ\n";
            }
        }
    }
}

sub ACTION_pure_install {
    shift()->depends_on('install');
}

sub ACTION_install {
    my ($self) = @_;
    require ExtUtils::Install;
    $self->depends_on('build');
    $self->_do_in_dir(
        ".",
        sub {
            ExtUtils::Install::install( $self->install_map, $self->verbose, 0,
                $self->{args}{uninst} || 0 );
        }
    );
    if ( $self->_is_ActivePerl && $self->{_completed_actions}{html} ) {
        $self->log_info("Building ActivePerl Table of Contents\n");
        eval {
            ActivePerl::DocTools::WriteTOC( verbose => $self->verbose ? 1 : 0 );
            1;
        }
          or $self->log_warn("AP::DT:: WriteTOC() failed: $@");
    }
    if ( $self->_is_ActivePPM ) {

        my $F_perllocal =
          File::Spec->catfile( $self->install_sets( 'core', 'lib' ),
            'perllocal.pod' );
        my $dt_stamp = time;

        $self->log_info("For ActivePerl's PPM: touch '$F_perllocal'\n");

        open my $perllocal, ">>", $F_perllocal;
        close $perllocal;
        utime( $dt_stamp, $dt_stamp, $F_perllocal );
    }
}

sub ACTION_fakeinstall {
    my ($self) = @_;
    require ExtUtils::Install;
    my $eui_version = ExtUtils::Install->VERSION;
    if ( $eui_version < 1.32 ) {
        $self->log_warn(
"The 'fakeinstall' action requires Extutils::Install 1.32 or later.\n"
              . "(You only have version $eui_version)." );
        return;
    }
    $self->depends_on('build');
    ExtUtils::Install::install( $self->install_map, !$self->quiet, 1,
        $self->{args}{uninst} || 0 );
}

sub ACTION_versioninstall {
    my ($self) = @_;

    die
      "You must have only.pm 0.25 or greater installed for this operation: $@\n"
      unless eval { require only; 'only'->VERSION(0.25); 1 };

    $self->depends_on('build');

    my %onlyargs =
      map { exists( $self->{args}{$_} ) ? ( $_ => $self->{args}{$_} ) : () }
      qw(version versionlib);
    only::install::install(%onlyargs);
}

sub ACTION_installdeps {
    my ($self) = @_;

    my $info = $self->_enum_prereqs;
    if ( !$info ) {
        $self->log_info("No prerequisites detected\n");
        return;
    }

    my $failures = $self->prereq_failures($info);
    if ( !$failures ) {
        $self->log_info("All prerequisites satisfied\n");
        return;
    }

    my @install;
    while ( my ( $type, $prereqs ) = each %$failures ) {
        if ( $type =~ m/^(?:\w+_)?requires$/ ) {
            push( @install, keys %$prereqs );
            next;
        }
        $self->log_info("Checking optional dependencies:\n");
        while ( my ( $module, $status ) = each %$prereqs ) {
            push( @install, $module )
              if ( $self->y_n( "Install $module?", 'y' ) );
        }
    }

    return unless @install;

    my ( $command, @opts ) = $self->split_like_shell( $self->cpan_client );

    if ( !File::Spec->file_name_is_absolute($command) ) {
        my @loc = ( 'site', 'vendor', '' );
        my @bindirs = File::Basename::dirname( $self->perl );
        push @bindirs, map {
            (
                $self->config->{"install${_}bin"},
                $self->config->{"install${_}script"}
              )
        } @loc;
        for my $d (@bindirs) {
            my $abs_cmd =
              $self->find_command( File::Spec->catfile( $d, $command ) );
            if ( defined $abs_cmd ) {
                $command = $abs_cmd;
                last;
            }
        }
    }

    if ( !-x $command ) {
        die "cpan_client '$command' is not executable\n";
    }

    $self->do_system( $command, @opts, @install );
}

sub ACTION_clean {
    my ($self) = @_;
    $self->log_info("Cleaning up build files\n");
    foreach my $item ( map glob($_), $self->cleanup ) {
        $self->delete_filetree($item);
    }
}

sub ACTION_realclean {
    my ($self) = @_;
    $self->depends_on('clean');
    $self->log_info("Cleaning up configuration files\n");
    $self->delete_filetree(
        $self->config_dir,  $self->mymetafile,
        $self->mymetafile2, $self->build_script
    );
}

sub ACTION_ppd {
    my ($self) = @_;

    require Module::Build::PPMMaker;
    my $ppd = Module::Build::PPMMaker->new();
    my $file = $ppd->make_ppd( %{ $self->{args} }, build => $self );
    $self->add_to_cleanup($file);
}

sub ACTION_ppmdist {
    my ($self) = @_;

    $self->depends_on('build');

    my $ppm = $self->ppm_name;
    $self->delete_filetree($ppm);
    $self->log_info("Creating $ppm\n");
    $self->add_to_cleanup( $ppm, "$ppm.tar.gz" );

    my %types = ( lib => 'lib',
        arch    => 'arch',
        bin     => 'bin',
        script  => 'script',
        bindoc  => 'man1',
        libdoc  => 'man3',
        binhtml => undef,
        libhtml => undef, );

    foreach my $type ( $self->install_types ) {
        next if exists( $types{$type} ) && !defined( $types{$type} );

        my $dir = File::Spec->catdir( $self->blib, $type );
        next unless -e $dir;

        my $files = $self->rscan_dir($dir);
        foreach my $file (@$files) {
            next unless -f $file;
            my $rel_file = File::Spec->abs2rel( File::Spec->rel2abs($file),
                File::Spec->rel2abs($dir) );
            my $to_file =
              File::Spec->catfile( $ppm, 'blib',
                exists( $types{$type} ) ? $types{$type} : $type, $rel_file );
            $self->copy_if_modified( from => $file, to => $to_file );
        }
    }

    foreach my $type (qw(bin lib)) {
        $self->htmlify_pods( $type,
            File::Spec->catdir( $ppm, 'blib', 'html' ) );
    }

    my $target = File::Spec->catfile( File::Spec->updir, $ppm );
    $self->_do_in_dir( $ppm, sub { $self->make_tarball( 'blib', $target ) } );

    $self->depends_on('ppd');

    $self->delete_filetree($ppm);
}

sub ACTION_pardist {
    my ($self) = @_;

    if ( not eval { require PAR::Dist; PAR::Dist->VERSION(0.17) } ) {
        $self->log_warn(
                "In order to create .par distributions, you need to\n"
              . "install PAR::Dist first." );
        return ();
    }

    $self->depends_on('build');

    return PAR::Dist::blib_to_par(
        name    => $self->dist_name,
        version => $self->dist_version,
    );
}

sub ACTION_dist {
    my ($self) = @_;

    $self->dispatch('distdir');

    my $dist_dir = $self->dist_dir;

    $self->make_tarball($dist_dir);
    $self->delete_filetree($dist_dir);
}

sub ACTION_distcheck {
    my ($self) = @_;

    $self->_check_manifest_skip unless $self->invoked_action eq 'distclean';

    require ExtUtils::Manifest;
    local $^W;
    my ( $missing, $extra ) = ExtUtils::Manifest::fullcheck();

    return unless @$missing || @$extra;

    my $msg = "MANIFEST appears to be out of sync with the distribution\n";
    if ( $self->invoked_action eq 'distcheck' ) {
        die $msg;
    }
    else {
        warn $msg;
    }
}

sub _check_mymeta_skip {
    my $self = shift;
    my $maniskip = shift || 'MANIFEST.SKIP';

    require ExtUtils::Manifest;
    local $^W;

    my $skip_factory = ExtUtils::Manifest->can('maniskip')
      || ExtUtils::Manifest->can('_maniskip');

    my $mymetafile = $self->mymetafile;
    for my $file ( $self->mymetafile, $self->mymetafile2 ) {
        unless ( $skip_factory && $skip_factory->($maniskip)->($file) ) {
            $self->log_warn(
                "File '$maniskip' does not include '$file'. Adding it now.\n");
            my $safe = quotemeta($file);
            $self->_append_maniskip( "^$safe\$", $maniskip );
        }
    }
}

sub _add_to_manifest {
    my ( $self, $manifest, $lines ) = @_;
    $lines = [$lines] unless ref $lines;

    my $existing_files = $self->_read_manifest($manifest);
    return unless defined($existing_files);

    @$lines = grep { !exists $existing_files->{$_} } @$lines
      or return;

    my $mode = ( stat $manifest )[2];
    chmod( $mode | oct(222), $manifest )
      or die "Can't make $manifest writable: $!";

    my $fh = IO::File->new("< $manifest") or die "Can't read $manifest: $!";
    my $last_line = (<$fh>)[-1] || "\n";
    my $has_newline = $last_line =~ /\n$/;
    $fh->close;

    $fh = IO::File->new(">> $manifest") or die "Can't write to $manifest: $!";
    print $fh "\n" unless $has_newline;
    print $fh map "$_\n", @$lines;
    close $fh;
    chmod( $mode, $manifest );

    $self->log_verbose( map "Added to $manifest: $_\n", @$lines );
}

sub _sign_dir {
    my ( $self, $dir ) = @_;

    unless ( eval { require Module::Signature; 1 } ) {
        $self->log_warn(
            "Couldn't load Module::Signature for 'distsign' action:\n $@\n");
        return;
    }

    {
        my $manifest = File::Spec->catfile( $dir, 'MANIFEST' );
        die "Signing a distribution requires a MANIFEST file"
          unless -e $manifest;
        $self->_add_to_manifest( $manifest,
            "SIGNATURE    Added here by Module::Build" );
    }

    $self->_do_in_dir( $dir,
        sub { local $Module::Signature::Quiet = 1; Module::Signature::sign() }
    );
}

sub _do_in_dir {
    my ( $self, $dir, $do ) = @_;

    my $start_dir = File::Spec->rel2abs( $self->cwd );
    chdir $dir or die "Can't chdir() to $dir: $!";
    eval { $do->() };
    my @err = $@ ? ($@) : ();
    chdir $start_dir or push @err, "Can't chdir() back to $start_dir: $!";
    die join "\n", @err if @err;
}

sub ACTION_distsign {
    my ($self) = @_;
    {
        local $self->{properties}{sign} = 0;
        $self->depends_on('distdir') unless -d $self->dist_dir;
    }
    $self->_sign_dir( $self->dist_dir );
}

sub ACTION_skipcheck {
    my ($self) = @_;

    require ExtUtils::Manifest;
    local $^W;
    ExtUtils::Manifest::skipcheck();
}

sub ACTION_distclean {
    my ($self) = @_;

    $self->depends_on('realclean');
    $self->depends_on('distcheck');
}

sub do_create_makefile_pl {
    my $self = shift;
    require Module::Build::Compat;
    $self->log_info("Creating Makefile.PL\n");
    eval {
        Module::Build::Compat->create_makefile_pl( $self->create_makefile_pl,
            $self, @_ );
    };
    if ($@) {
        1 while unlink 'Makefile.PL';
        die "$@\n";
    }
    $self->_add_to_manifest( 'MANIFEST', 'Makefile.PL' );
}

sub do_create_license {
    my $self = shift;
    $self->log_info("Creating LICENSE file\n");

    if ( !$self->_mb_feature('license_creation') ) {
        $self->_warn_mb_feature_deps('license_creation');
        die "Aborting.\n";
    }

    my $l = $self->license
      or die "Can't create LICENSE file: No license specified\n";

    my $license = $self->_software_license_object
      or die << "HERE";
Can't create LICENSE file: '$l' is not a valid license key
or Software::License subclass;
HERE

    $self->delete_filetree('LICENSE');

    my $fh = IO::File->new('> LICENSE')
      or die "Can't write LICENSE file: $!";
    print $fh $license->fulltext;
    close $fh;

    $self->_add_to_manifest( 'MANIFEST', 'LICENSE' );
}

sub do_create_readme {
    my $self = shift;
    $self->delete_filetree('README');

    my $docfile = $self->_main_docfile;
    unless ($docfile) {
        $self->log_warn(<<EOF);
Cannot create README: can't determine which file contains documentation;
Must supply either 'dist_version_from', or 'module_name' parameter.
EOF
        return;
    }

    if ( eval { require Pod::Readme; Pod::Readme->can('new') } ) {
        $self->log_info("Creating README using Pod::Readme\n");

        my $parser = Pod::Readme->new;
        $parser->parse_from_file( $docfile, 'README', @_ );

    }
    elsif ( eval { require Pod::Text; 1 } ) {
        $self->log_info("Creating README using Pod::Text\n");

        my $fh = IO::File->new('> README');
        if ( defined($fh) ) {
            local $^W = 0;
            no strict "refs";

            my $old_parse_file;
            $old_parse_file = \&{"Pod::Simple::parse_file"}
              and local *{"Pod::Simple::parse_file"} = sub {
                my $self = shift;
                $self->output_fh( $_[1] ) if $_[1];
                $self->$old_parse_file( $_[0] );
              }
              if $Pod::Text::VERSION == 3.01;

            Pod::Text::pod2text( $docfile, $fh );

            $fh->close;
        }
        else {
            $self->log_warn(
                "Cannot create 'README' file: Can't open file for writing\n");
            return;
        }

    }
    else {
        $self->log_warn(
            "Can't load Pod::Readme or Pod::Text to create README\n");
        return;
    }

    $self->_add_to_manifest( 'MANIFEST', 'README' );
}

sub _main_docfile {
    my $self = shift;
    if ( my $pm_file = $self->dist_version_from ) {
        ( my $pod_file = $pm_file ) =~ s/.pm$/.pod/;
        return ( -e $pod_file ? $pod_file : $pm_file );
    }
    else {
        return undef;
    }
}

sub do_create_bundle_inc {
    my $self = shift;
    my $dist_inc = File::Spec->catdir( $self->dist_dir, 'inc' );
    require inc::latest;
    inc::latest->write( $dist_inc, @{ $self->bundle_inc_preload } );
    inc::latest->bundle_module( $_, $dist_inc ) for @{ $self->bundle_inc };
    return 1;
}

sub ACTION_distdir {
    my ($self) = @_;

    if ( @{ $self->bundle_inc } && !$self->_mb_feature('inc_bundling_support') )
    {
        $self->_warn_mb_feature_deps('inc_bundling_support');
        die "Aborting.\n";
    }

    $self->depends_on('distmeta');

    my $dist_files = $self->_read_manifest('MANIFEST')
      or die
"Can't create distdir without a MANIFEST file - run 'manifest' action first.\n";
    delete $dist_files->{SIGNATURE};
    die "No files found in MANIFEST - try running 'manifest' action?\n"
      unless ( $dist_files and keys %$dist_files );
    my $metafile = $self->metafile;
    $self->log_warn("*** Did you forget to add $metafile to the MANIFEST?\n")
      unless exists $dist_files->{$metafile};

    my $dist_dir = $self->dist_dir;
    $self->delete_filetree($dist_dir);
    $self->log_info("Creating $dist_dir\n");
    $self->add_to_cleanup($dist_dir);

    foreach my $file ( keys %$dist_files ) {
        next if $file =~ m{^MYMETA\.};
        my $new = $self->copy_if_modified(
            from    => $file,
            to_dir  => $dist_dir,
            verbose => 0
        );
    }

    $self->do_create_bundle_inc if @{ $self->bundle_inc };

    $self->_sign_dir($dist_dir) if $self->{properties}{sign};
}

sub ACTION_disttest {
    my ($self) = @_;

    $self->depends_on('distdir');

    $self->_do_in_dir(
        $self->dist_dir,
        sub {

            $self->run_perl_script('Build.PL') or die
              "Error executing 'Build.PL' in dist directory: $!";
            $self->run_perl_script('Build')
              or die "Error executing 'Build' in dist directory: $!";
            $self->run_perl_script( 'Build', [], ['test'] )
              or die "Error executing 'Build test' in dist directory";
        }
    );
}

sub ACTION_distinstall {
    my ( $self, @args ) = @_;

    $self->depends_on('distdir');

    $self->_do_in_dir(
        $self->dist_dir,
        sub {
            $self->run_perl_script('Build.PL')
              or die "Error executing 'Build.PL' in dist directory: $!";
            $self->run_perl_script('Build')
              or die "Error executing 'Build' in dist directory: $!";
            $self->run_perl_script( 'Build', [], ['install'] )
              or die "Error executing 'Build install' in dist directory";
        }
    );
}


sub _eumanifest_has_include {
    my $self = shift;

    require ExtUtils::Manifest;
    return eval { ExtUtils::Manifest->VERSION(1.50); 1 };
}


sub _default_maniskip {
    my $self = shift;

    my $default_maniskip;
    for my $dir (@INC) {
        $default_maniskip =
          File::Spec->catfile( $dir, "ExtUtils", "MANIFEST.SKIP" );
        last if -r $default_maniskip;
    }

    return $default_maniskip;
}


sub _slurp {
    my $self = shift;
    my $file = shift;
    my $mode = shift || "";
    open my $fh, "<$mode", $file or croak "Can't open $file for reading: $!";
    local $/;
    return <$fh>;
}

sub _spew {
    my $self    = shift;
    my $file    = shift;
    my $content = shift || "";
    my $mode    = shift || "";
    open my $fh, ">$mode", $file or croak "Can't open $file for writing: $!";
    print {$fh} $content;
    close $fh;
}

sub _case_tolerant {
    my $self = shift;
    if ( ref $self ) {
        $self->{_case_tolerant} = File::Spec->case_tolerant
          unless defined( $self->{_case_tolerant} );
        return $self->{_case_tolerant};
    }
    else {
        return File::Spec->case_tolerant;
    }
}

sub _append_maniskip {
    my $self = shift;
    my $skip = shift;
    my $file = shift || 'MANIFEST.SKIP';
    return unless defined $skip && length $skip;
    my $fh = IO::File->new(">> $file")
      or die "Can't open $file: $!";

    print $fh "$skip\n";
    $fh->close();
}

sub _write_default_maniskip {
    my $self = shift;
    my $file = shift || 'MANIFEST.SKIP';
    my $fh   = IO::File->new("> $file")
      or die "Can't open $file: $!";

    my $content =
      $self->_eumanifest_has_include
      ? "#!include_default\n"
      : $self->_slurp( $self->_default_maniskip );

    $content .= <<'EOF';
# Avoid configuration metadata file
^MYMETA\.

# Avoid Module::Build generated and utility files.
\bBuild$
\bBuild.bat$
\b_build
\bBuild.COM$
\bBUILD.COM$
\bbuild.com$
^MANIFEST\.SKIP

# Avoid archives of this distribution
EOF

    $content .= '\b' . $self->dist_name . '-[\d\.\_]+' . "\n";

    print $fh $content;

    return;
}

sub _check_manifest_skip {
    my ($self) = @_;

    my $maniskip = 'MANIFEST.SKIP';

    if ( !-e $maniskip ) {
        $self->log_warn(
"File '$maniskip' does not exist: Creating a temporary '$maniskip'\n"
        );
        $self->_write_default_maniskip($maniskip);
        $self->_unlink_on_exit($maniskip);
    }
    else {
        $self->_check_mymeta_skip($maniskip);
    }

    return;
}

sub ACTION_manifest {
    my ($self) = @_;

    $self->_check_manifest_skip;

    require ExtUtils::Manifest;
    local ( $^W, $ExtUtils::Manifest::Quiet ) = ( 0, 1 );
    ExtUtils::Manifest::mkmanifest();
}

sub ACTION_manifest_skip {
    my ($self) = @_;

    if ( -e 'MANIFEST.SKIP' ) {
        $self->log_warn("MANIFEST.SKIP already exists.\n");
        return 0;
    }
    $self->log_info("Creating a new MANIFEST.SKIP file\n");
    return $self->_write_default_maniskip;
    return -e 'MANIFEST.SKIP';
}

sub file_qr {
    return shift->{_case_tolerant} ? qr($_[0])i : qr($_[0]);
}

sub dist_dir {
    my ($self) = @_;
    my $dir = join "-", $self->dist_name, $self->dist_version;
    $dir .= "-" . $self->dist_suffix if $self->dist_suffix;
    return $dir;
}

sub ppm_name {
    my $self = shift;
    return 'PPM-' . $self->dist_dir;
}

sub _files_in {
    my ( $self, $dir ) = @_;
    return unless -d $dir;

    local *DH;
    opendir DH, $dir or die "Can't read directory $dir: $!";

    my @files;
    while ( defined( my $file = readdir DH ) ) {
        my $full_path = File::Spec->catfile( $dir, $file );
        next if -d $full_path;
        push @files, $full_path;
    }
    return @files;
}

sub share_dir {
    my $self = shift;
    my $p    = $self->{properties};

    $p->{share_dir} = shift if @_;

    if ( !defined $p->{share_dir} ) {
        return;
    }
    elsif ( !ref $p->{share_dir} ) {
        $p->{share_dir} = { dist => [ $p->{share_dir} ] };
    }
    elsif ( ref $p->{share_dir} eq 'ARRAY' ) {
        $p->{share_dir} = { dist => $p->{share_dir} };
    }
    elsif ( ref $p->{share_dir} eq 'HASH' ) {
        my $share_dir = $p->{share_dir};
        if ( defined $share_dir->{dist} ) {
            if ( !ref $share_dir->{dist} ) {
                $share_dir->{dist} = [ $share_dir->{dist} ];
            }
            elsif ( ref $share_dir->{dist} ne 'ARRAY' ) {
                die "'dist' key in 'share_dir' must be scalar or arrayref";
            }
        }
        if ( defined $share_dir->{module} ) {
            my $mod_hash = $share_dir->{module};
            if ( ref $mod_hash eq 'HASH' ) {
                for my $k ( keys %$mod_hash ) {
                    if ( !ref $mod_hash->{$k} ) {
                        $mod_hash->{$k} = [ $mod_hash->{$k} ];
                    }
                    elsif ( ref $mod_hash->{$k} ne 'ARRAY' ) {
                        die
"modules in 'module' key of 'share_dir' must be scalar or arrayref";
                    }
                }
            }
            else {
                die "'module' key in 'share_dir' must be hashref";
            }
        }
    }
    else {
        die "'share_dir' must be hashref, arrayref or string";
    }

    return $p->{share_dir};
}

sub script_files {
    my $self = shift;

    for ( $self->{properties}{script_files} ) {
        $_ = shift if @_;
        next unless $_;

        return $_ if UNIVERSAL::isa( $_, 'HASH' );
        return $_ = { map { $_, 1 } @$_ } if UNIVERSAL::isa( $_, 'ARRAY' );

        die "'script_files' must be a hashref, arrayref, or string" if ref();

        return $_ = { map { $_, 1 } $self->_files_in($_) } if -d $_;
        return $_ = { $_ => 1 };
    }

    my %pl_files =
      map { File::Spec->canonpath($_) => 1 } keys %{ $self->PL_files || {} };

    my @bin_files = $self->_files_in('bin');

    my %bin_map = map { $_ => File::Spec->canonpath($_) } @bin_files;

    return $_ = { map { $_ => 1 } grep !$pl_files{ $bin_map{$_} }, @bin_files };
}
BEGIN { *scripts = \&script_files; }

{
    my %licenses = (
        perl         => 'Perl_5',
        apache       => 'Apache_2_0',
        apache_1_1   => 'Apache_1_1',
        artistic     => 'Artistic_1_0',
        artistic_2   => 'Artistic_2_0',
        lgpl         => 'LGPL_2_1',
        lgpl2        => 'LGPL_2_1',
        lgpl3        => 'LGPL_3_0',
        bsd          => 'BSD',
        gpl          => 'GPL_1',
        gpl2         => 'GPL_2',
        gpl3         => 'GPL_3',
        mit          => 'MIT',
        mozilla      => 'Mozilla_1_1',
        open_source  => undef,
        unrestricted => undef,
        restrictive  => undef,
        unknown      => undef,
    );

    my %license_urls = (
        perl       => 'http://dev.perl.org/licenses/',
        apache     => 'http://apache.org/licenses/LICENSE-2.0',
        apache_1_1 => 'http://apache.org/licenses/LICENSE-1.1',
        artistic   => 'http://opensource.org/licenses/artistic-license.php',
        artistic_2 => 'http://opensource.org/licenses/artistic-license-2.0.php',
        lgpl       => 'http://opensource.org/licenses/lgpl-license.php',
        lgpl2      => 'http://opensource.org/licenses/lgpl-2.1.php',
        lgpl3      => 'http://opensource.org/licenses/lgpl-3.0.html',
        bsd        => 'http://opensource.org/licenses/bsd-license.php',
        gpl        => 'http://opensource.org/licenses/gpl-license.php',
        gpl2       => 'http://opensource.org/licenses/gpl-2.0.php',
        gpl3       => 'http://opensource.org/licenses/gpl-3.0.html',
        mit        => 'http://opensource.org/licenses/mit-license.php',
        mozilla    => 'http://opensource.org/licenses/mozilla1.1.php',
        open_source  => undef,
        unrestricted => undef,
        restrictive  => undef,
        unknown      => undef,
    );

    sub valid_licenses {
        return \%licenses;
    }

    sub _license_url {
        return $license_urls{ $_[1] };
    }
}

sub _software_license_object {
    my ($self) = @_;
    return unless defined( my $license = $self->license );

    my $class;
  LICENSE: for my $l ( $self->valid_licenses->{$license}, $license ) {
        next unless defined $l;
        my $trial = "Software::License::" . $l;
        if (
            eval
"require Software::License; Software::License->VERSION(0.014); require $trial; 1"
          )
        {
            $class = $trial;
            last LICENSE;
        }
    }
    return unless defined $class;

    my $author = join( " & ", @{ $self->dist_author } ) || 'unknown';
    my $sl = eval { $class->new( { holder => $author } ) };
    if ($@) {
        $self->log_warn("Error getting '$class' object: $@");
    }

    return $sl;
}

sub _hash_merge {
    my ( $self, $h, $k, $v ) = @_;
    if ( ref $h->{$k} eq 'ARRAY' ) {
        push @{ $h->{$k} }, ref $v ? @$v : $v;
    }
    elsif ( ref $h->{$k} eq 'HASH' ) {
        $h->{$k}{$_} = $v->{$_} foreach keys %$v;
    }
    else {
        $h->{$k} = $v;
    }
}

sub ACTION_distmeta {
    my ($self) = @_;
    $self->do_create_makefile_pl if $self->create_makefile_pl;
    $self->do_create_readme      if $self->create_readme;
    $self->do_create_license     if $self->create_license;
    $self->do_create_metafile;
}

sub do_create_metafile {
    my $self = shift;
    return if $self->{wrote_metadata};

    my $p = $self->{properties};

    unless ( $p->{license} ) {
        $self->log_warn("No license specified, setting license = 'unknown'\n");
        $p->{license} = 'unknown';
    }

    my @metafiles = ( $self->metafile, $self->metafile2 );
    $self->delete_filetree($_) for @metafiles;

    local @INC = @INC;
    if ( ( $self->module_name || '' ) eq 'Module::Build' ) {
        $self->depends_on('config_data');
        push @INC, File::Spec->catdir( $self->blib, 'lib' );
    }

    my $meta_obj = $self->_get_meta_object(
        quiet => 1,
        fatal => 1,
        auto  => 1
    );
    my @created = $self->_write_meta_files( $meta_obj, 'META' );
    if (@created) {
        $self->{wrote_metadata} = 1;
        $self->_add_to_manifest( 'MANIFEST', $_ ) for @created;
    }
    return 1;
}

sub _write_meta_files {
    my $self = shift;
    my ( $meta, $file ) = @_;
    $file =~ s{\.(?:yml|json)$}{};

    my @created;
    push @created, "$file\.yml"
      if $meta && $meta->save( "$file\.yml", { version => "1.4" } );
    push @created, "$file\.json"
      if $meta && $meta->save("$file\.json");

    if (@created) {
        $self->log_info( "Created " . join( " and ", @created ) . "\n" );
    }
    return @created;
}

sub _get_meta_object {
    my $self = shift;
    my %args = @_;
    return unless $self->try_require( "CPAN::Meta", "2.110420" );

    my $meta;
    eval {
        my $data = $self->get_metadata(
            fatal => $args{fatal},
            auto  => $args{auto},
        );
        $data->{dynamic_config} = $args{dynamic} if defined $args{dynamic};
        $meta = CPAN::Meta->create($data);
    };
    if ( $@ && !$args{quiet} ) {
        $self->log_warn( "Could not get valid metadata. Error is: $@\n" );
    }

    return $meta;
}

sub read_metafile {
    my $self = shift;
    my ($metafile) = @_;

    return unless $self->try_require( "CPAN::Meta", "2.110420" );
    my $meta = CPAN::Meta->load_file($metafile);
    return $meta->as_struct( { version => "1.4" } );
}

sub write_metafile {
    my $self = shift;
    my ( $metafile, $struct ) = @_;

    return unless $self->try_require( "CPAN::Meta", "2.110420" );

    my $meta = CPAN::Meta->new($struct);
    return $meta->save( $metafile, { version => "1.4" } );
}

sub normalize_version {
    my ( $self, $version ) = @_;
    $version = 0 unless defined $version and length $version;

    if ( $version =~ /[=<>!,]/ ) { ;
    }
    elsif (ref $version eq 'version'
        || ref $version eq 'Module::Build::Version' )
    { $version = $version->is_qv ? $version->normal : $version->stringify;
    }
    elsif ( $version =~ /^[^v][^.]*\.[^.]+\./ ) {  $version = "v$version";
    }
    else {
    }
    return $version;
}

sub _normalize_prereqs {
    my ($self) = @_;
    my $p = $self->{properties};

    my %prereq_types;
    for my $type ( 'configure_requires', @{ $self->prereq_action_types } ) {
        if ( exists $p->{$type} ) {
            for my $mod ( keys %{ $p->{$type} } ) {
                $prereq_types{$type}{$mod} =
                  $self->normalize_version( $p->{$type}{$mod} );
            }
        }
    }
    return \%prereq_types;
}

sub get_metadata {
    my ( $self, %args ) = @_;
    my $metadata = {};
    $self->prepare_metadata( $metadata, undef, \%args );
    return $metadata;
}

sub prepare_metadata {
    my ( $self, $node, $keys, $args ) = @_;
    unless ( ref $node eq 'HASH' ) {
        croak "prepare_metadata() requires a hashref argument to hold output\n";
    }
    my $fatal = $args->{fatal} || 0;
    my $p = $self->{properties};

    $self->auto_config_requires if $args->{auto};

    my $add_node = sub {
        my ( $name, $val ) = @_;
        $node->{$name} = $val;
        push @$keys, $name if $keys;
    };

    foreach my $f (qw(dist_name dist_version dist_author dist_abstract license))
    {
        my $field = $self->$f();
        unless ( defined $field and length $field ) {
            my $err = "ERROR: Missing required field '$f' for metafile\n";
            if ($fatal) {
                die $err;
            }
            else {
                $self->log_warn($err);
            }
        }
    }

    foreach my $f (qw(dist_name dist_version dist_author dist_abstract)) {
        ( my $name = $f ) =~ s/^dist_//;
        $add_node->( $name, $self->$f() );
    }

    $node->{version} = $self->normalize_version( $node->{version} );

    my $license = $self->license;
    my ( $meta_license, $meta_license_url );

    if ( my $sl = $self->_software_license_object ) {
        $meta_license     = $sl->meta_name;
        $meta_license_url = $sl->url;
    }
    elsif ( exists $self->valid_licenses()->{$license} ) {
        $meta_license     = $license;
        $meta_license_url = $self->_license_url($license);
    }
    else {
        $self->log_warn( "Can not determine license type for '"
              . $self->license
              . "'\nSetting META license field to 'unknown'.\n" );
        $meta_license = 'unknown';
    }

    $node->{license} = $meta_license;
    $node->{resources}{license} = $meta_license_url
      if defined $meta_license_url;

    my $prereqs = $self->_normalize_prereqs;
    for my $t ( keys %$prereqs ) {
        $add_node->( $t, $prereqs->{$t} );
    }

    if ( exists $p->{dynamic_config} ) {
        $add_node->( 'dynamic_config', $p->{dynamic_config} );
    }
    my $pkgs = eval { $self->find_dist_packages };
    if ($@) {
        $self->log_warn(
                "$@\nWARNING: Possible missing or corrupt 'MANIFEST' file.\n"
              . "Nothing to enter for 'provides' field in metafile.\n" );
    }
    else {
        $node->{provides} = $pkgs if %$pkgs;
    }
    if ( exists $p->{no_index} ) {
        $add_node->( 'no_index', $p->{no_index} );
    }

    $add_node->(
        'generated_by', "Module::Build version $Module::Build::VERSION"
    );

    $add_node->(
        'meta-spec',
        {
            version => '1.4',
            url => 'http://module-build.sourceforge.net/META-spec-v1.4.html',
        }
    );

    while ( my ( $k, $v ) = each %{ $self->meta_add } ) {
        $add_node->( $k, $v );
    }

    while ( my ( $k, $v ) = each %{ $self->meta_merge } ) {
        $self->_hash_merge( $node, $k, $v );
    }

    return $node;
}

sub _read_manifest {
    my ( $self, $file ) = @_;
    return undef unless -e $file;

    require ExtUtils::Manifest;
    local ( $^W, $ExtUtils::Manifest::Quiet ) = ( 0, 1 );
    return scalar ExtUtils::Manifest::maniread($file);
}

sub find_dist_packages {
    my $self = shift;

    my $manifest = $self->_read_manifest('MANIFEST')
      or die
"Can't find dist packages without a MANIFEST file\nRun 'Build manifest' to generate one\n";

    my %dist_files = map { $self->localize_file_path($_) => $_ }
      keys %$manifest;

    my @pm_files = grep { $_ !~ m{^t} } grep { exists $dist_files{$_} }
      keys %{ $self->find_pm_files };

    return $self->find_packages_in_files( \@pm_files, \%dist_files );
}

sub find_packages_in_files {
    my ( $self, $file_list, $filename_map ) = @_;

    my ( %prime, %alt );
    foreach my $file ( @{$file_list} ) {
        my $mapped_filename = $filename_map->{$file};
        my @path = split( /\//, $mapped_filename );
        ( my $prime_package = join( '::', @path[ 1 .. $#path ] ) ) =~ s/\.pm$//;

        my $pm_info = Module::Build::ModuleInfo->new_from_file($file);

        foreach my $package ( $pm_info->packages_inside ) {
            next if $package eq 'main';
            next if $package eq 'DB';
            next if grep /^_/, split( /::/, $package );

            my $version = $pm_info->version($package);

            if ( $package eq $prime_package ) {
                if ( exists( $prime{$package} ) ) {
                    die
"Unexpected conflict in '$package'; multiple versions found.\n";
                }
                else {
                    $prime{$package}{file} = $mapped_filename;
                    $prime{$package}{version} = $version if defined($version);
                }
            }
            else {
                push(
                    @{ $alt{$package} },
                    {
                        file    => $mapped_filename,
                        version => $version,
                    }
                );
            }
        }
    }

    foreach my $package ( keys(%alt) ) {
        my $result = $self->_resolve_module_versions( $alt{$package} );

        if ( exists( $prime{$package} ) ) {

            if ( $result->{err} ) {
                $self->log_warn(
                        "Found conflicting versions for package '$package'\n"
                      . "  $prime{$package}{file} ($prime{$package}{version})\n"
                      . $result->{err} );

            }
            elsif ( defined( $result->{version} ) ) {

                if ( exists( $prime{$package}{version} )
                    && defined( $prime{$package}{version} ) )
                {
                    if (
                        $self->compare_versions(
                            $prime{$package}{version}, '!=',
                            $result->{version}
                        )
                      )
                    {
                        $self->log_warn(
"Found conflicting versions for package '$package'\n"
                              . "  $prime{$package}{file} ($prime{$package}{version})\n"
                              . "  $result->{file} ($result->{version})\n" );
                    }

                }
                else {
                    $prime{$package}{file}    = $result->{file};
                    $prime{$package}{version} = $result->{version};
                }

            }
            else {
            }

        }
        else {

            if ( $result->{err} ) {
                $self->log_warn(
                    "Found conflicting versions for package '$package'\n"
                      . $result->{err} );
            }

            $prime{$package}{file}    = $result->{file};
            $prime{$package}{version} = $result->{version}
              if defined( $result->{version} );
        }
    }

    for ( grep defined $_->{version}, values %prime ) {
        $_->{version} = $self->normalize_version( $_->{version} );
    }

    return \%prime;
}

sub _resolve_module_versions {
    my $self = shift;

    my $packages = shift;

    my ( $file, $version );
    my $err = '';
    foreach my $p (@$packages) {
        if ( defined( $p->{version} ) ) {
            if ( defined($version) ) {
                if ( $self->compare_versions( $version, '!=', $p->{version} ) )
                {
                    $err .= "  $p->{file} ($p->{version})\n";
                }
                else {
                }
            }
            else {
                $file    = $p->{file};
                $version = $p->{version};
            }
        }
        $file ||= $p->{file} if defined( $p->{file} );
    }

    if ($err) {
        $err = "  $file ($version)\n" . $err;
    }

    my %result = (
        file    => $file,
        version => $version,
        err     => $err
    );

    return \%result;
}

sub make_tarball {
    my ( $self, $dir, $file ) = @_;
    $file ||= $dir;

    $self->log_info("Creating $file.tar.gz\n");

    if ( $self->{args}{tar} ) {
        my $tar_flags = $self->verbose ? 'cvf' : 'cf';
        $self->do_system( $self->split_like_shell( $self->{args}{tar} ),
            $tar_flags, "$file.tar", $dir );
        $self->do_system( $self->split_like_shell( $self->{args}{gzip} ),
            "$file.tar" )
          if $self->{args}{gzip};
    }
    else {
        eval { require Archive::Tar && Archive::Tar->VERSION(1.09); 1 }
          or die
          "You must install Archive::Tar 1.09+ to make a distribution tarball\n"
          . "or specify a binary tar program with the '--tar' option.\n"
          . "See the documentation for the 'dist' action.\n";

        my $files = $self->rscan_dir($dir);

        $Archive::Tar::DO_NOT_USE_PREFIX =
          ( grep { length($_) >= 100 } @$files ) ? 0 : 1;

        my $tar = Archive::Tar->new;
        $tar->add_files(@$files);
        for my $f ( $tar->get_files ) {
            $f->mode( $f->mode & ~022 );
        }
        $tar->write( "$file.tar.gz", 1 );
    }
}

sub install_path {
    my $self = shift;
    my ( $type, $value ) = ( @_, '<empty>' );

    Carp::croak('Type argument missing')
      unless defined($type);

    my $map = $self->{properties}{install_path};
    return $map unless @_;

    unless ( defined($value) ) {
        delete( $map->{$type} );
        return undef;
    }

    if ( $value eq '<empty>' ) {
        return undef unless exists $map->{$type};
        return $map->{$type};
    }

    return $map->{$type} = $value;
}

sub install_sets {
    my ( $self, $dirs, $key, $value ) = @_;
    $dirs = $self->installdirs unless defined $dirs;
    if ( @_ == 4 && defined $dirs && defined $key ) {
        $self->{properties}{install_sets}{$dirs}{$key} = $value;
    }
    my $map = {
        $self->_merge_arglist(
            $self->{properties}{install_sets},
            $self->_default_install_paths->{install_sets}
        )
    };
    if ( defined $dirs && defined $key ) {
        return $map->{$dirs}{$key};
    }
    elsif ( defined $dirs ) {
        return $map->{$dirs};
    }
    else {
        croak "Can't determine installdirs for install_sets()";
    }
}

sub original_prefix {
    my ( $self, $key, $value ) = @_;
    if ( @_ == 3 && defined $key ) {
        $self->{properties}{original_prefix}{$key} = $value;
    }
    my $map = {
        $self->_merge_arglist(
            $self->{properties}{original_prefix},
            $self->_default_install_paths->{original_prefix}
        )
    };
    return $map unless defined $key;
    return $map->{$key};
}

sub install_base_relpaths {
    my $self = shift;
    if ( @_ > 1 )
    { $self->_set_relpaths( $self->{properties}{install_base_relpaths}, @_ );
    }
    my $map = {
        $self->_merge_arglist(
            $self->{properties}{install_base_relpaths},
            $self->_default_install_paths->{install_base_relpaths}
        )
    };
    return $map unless @_;
    my $relpath = $map->{ $_[0] };
    return defined $relpath ? File::Spec->catdir(@$relpath) : undef;
}

sub prefix_relpaths {
    my $self = shift;
    my $installdirs = shift || $self->installdirs
      or croak "Can't determine installdirs for prefix_relpaths()";
    if ( @_ > 1 ) { $self->{properties}{prefix_relpaths}{$installdirs} ||= {};
        $self->_set_relpaths(
            $self->{properties}{prefix_relpaths}{$installdirs}, @_ );
    }
    my $map = {
        $self->_merge_arglist(
            $self->{properties}{prefix_relpaths}{$installdirs},
            $self->_default_install_paths->{prefix_relpaths}{$installdirs}
        )
    };
    return $map unless @_;
    my $relpath = $map->{ $_[0] };
    return defined $relpath ? File::Spec->catdir(@$relpath) : undef;
}

sub _set_relpaths {
    my $self = shift;
    my ( $map, $type, $value ) = @_;

    Carp::croak('Type argument missing')
      unless defined($type);

    if ( !defined($value) ) {
        $map->{$type} = undef;
        return;
    }
    else {
        Carp::croak("Value must be a relative path")
          if File::Spec::Unix->file_name_is_absolute($value);

        my @value = split( /\//, $value );
        $map->{$type} = \@value;
    }
}

sub prefix_relative {
    my ( $self, $type ) = @_;
    my $installdirs = $self->installdirs;

    my $relpath = $self->install_sets($installdirs)->{$type};

    return $self->_prefixify( $relpath, $self->original_prefix($installdirs),
        $type, );
}

sub _prefixify {
    my ( $self, $path, $sprefix, $type ) = @_;

    my $rprefix = $self->prefix;
    $rprefix .= '/' if $sprefix =~ m|/$|;

    $self->log_verbose("  prefixify $path from $sprefix to $rprefix\n")
      if defined($path) && length($path);

    if ( !defined($path) || ( length($path) == 0 ) ) {
        $self->log_verbose(
            "  no path to prefixify, falling back to default.\n");
        return $self->_prefixify_default( $type, $rprefix );
    }
    elsif ( !File::Spec->file_name_is_absolute($path) ) {
        $self->log_verbose("    path is relative, not prefixifying.\n");
    }
    elsif ( $path !~ s{^\Q$sprefix\E\b}{}s ) {
        $self->log_verbose("    cannot prefixify, falling back to default.\n");
        return $self->_prefixify_default( $type, $rprefix );
    }

    $self->log_verbose("    now $path in $rprefix\n");

    return $path;
}

sub _prefixify_default {
    my $self    = shift;
    my $type    = shift;
    my $rprefix = shift;

    my $default = $self->prefix_relpaths( $self->installdirs, $type );
    if ( !$default ) {
        $self->log_verbose(
"    no default install location for type '$type', using prefix '$rprefix'.\n"
        );
        return $rprefix;
    }
    else {
        return $default;
    }
}

sub install_destination {
    my ( $self, $type ) = @_;

    return $self->install_path($type) if $self->install_path($type);

    if ( $self->install_base ) {
        my $relpath = $self->install_base_relpaths($type);
        return $relpath
          ? File::Spec->catdir( $self->install_base, $relpath )
          : undef;
    }

    if ( $self->prefix ) {
        my $relpath = $self->prefix_relative($type);
        return $relpath ? File::Spec->catdir( $self->prefix, $relpath ) : undef;
    }

    return $self->install_sets( $self->installdirs )->{$type};
}

sub install_types {
    my $self = shift;

    my %types;
    if ( $self->install_base ) {
        %types = %{ $self->install_base_relpaths };
    }
    elsif ( $self->prefix ) {
        %types = %{ $self->prefix_relpaths };
    }
    else {
        %types = %{ $self->install_sets( $self->installdirs ) };
    }

    %types = ( %types, %{ $self->install_path } );

    return sort keys %types;
}

sub install_map {
    my ( $self, $blib ) = @_;
    $blib ||= $self->blib;

    my ( %map, @skipping );
    foreach my $type ( $self->install_types ) {
        my $localdir = File::Spec->catdir( $blib, $type );
        next unless -e $localdir;

        if ( my $dest = $self->install_destination($type) ) {
            $map{$localdir} = $dest;
        }
        else {
            push( @skipping, $type );
        }
    }

    $self->log_warn(
            "WARNING: Can't figure out install path for types: @skipping\n"
          . "Files will not be installed.\n" )
      if @skipping;

    if ( $self->create_packlist and my $module_name = $self->module_name ) {
        my $archdir = $self->install_destination('arch');
        my @ext = split /::/, $module_name;
        $map{write} =
          File::Spec->catfile( $archdir, 'auto', @ext, '.packlist' );
    }

    if ( length( my $destdir = $self->destdir || '' ) ) {
        foreach ( keys %map ) {
            my ( $volume, $path, $file ) = File::Spec->splitpath( $map{$_}, 0 );

            my @dirs = File::Spec->splitdir($path);

            $path = File::Spec->catdir( $destdir, @dirs );

            if ( $file ne '' ) {
                $map{$_} = File::Spec->catfile( $path, $file );
            }
            else {
                $map{$_} = $path;
            }
        }
    }

    $map{read} = '';

    return \%map;
}

sub depends_on {
    my $self = shift;
    foreach my $action (@_) {
        $self->_call_action($action);
    }
}

sub rscan_dir {
    my ( $self, $dir, $pattern ) = @_;
    my @result;
    local $_;
    my $subr =
        !$pattern ? sub { push @result, $File::Find::name }
      : !ref($pattern)
      || ( ref $pattern eq 'Regexp' )
      ? sub { push @result, $File::Find::name if /$pattern/ }
      : ref($pattern) eq 'CODE'
      ? sub { push @result, $File::Find::name if $pattern->() }
      : die "Unknown pattern type";

    File::Find::find( { wanted => $subr, no_chdir => 1 }, $dir );
    return \@result;
}

sub delete_filetree {
    my $self    = shift;
    my $deleted = 0;
    foreach (@_) {
        next unless -e $_;
        $self->log_verbose("Deleting $_\n");
        File::Path::rmtree( $_, 0, 0 );
        die "Couldn't remove '$_': $!\n" if -e $_;
        $deleted++;
    }
    return $deleted;
}

sub autosplit_file {
    my ( $self, $file, $to ) = @_;
    require AutoSplit;
    my $dir = File::Spec->catdir( $to, 'lib', 'auto' );
    AutoSplit::autosplit( $file, $dir );
}

sub cbuilder {

    my $self = shift;
    my $s    = $self->{stash};
    return $s->{_cbuilder} if $s->{_cbuilder};

    require ExtUtils::CBuilder;
    return $s->{_cbuilder} = ExtUtils::CBuilder->new(
        config => $self->config,
        ( $self->quiet ? ( quiet => 1 ) : () ),
    );
}

sub have_c_compiler {
    my ($self) = @_;

    my $p = $self->{properties};
    return $p->{_have_c_compiler} if defined $p->{_have_c_compiler};

    $self->log_verbose("Checking if compiler tools configured... ");
    my $b = eval { $self->cbuilder };
    my $have = $b && eval { $b->have_compiler };
    $self->log_verbose( $have ? "ok.\n" : "failed.\n" );
    return $p->{_have_c_compiler} = $have;
}

sub compile_c {
    my ( $self, $file, %args ) = @_;

    if ( !$self->have_c_compiler ) {
        die "Error: no compiler detected to compile '$file'.  Aborting\n";
    }

    my $b        = $self->cbuilder;
    my $obj_file = $b->object_file($file);
    $self->add_to_cleanup($obj_file);
    return $obj_file if $self->up_to_date( $file, $obj_file );

    $b->compile(
        source               => $file,
        defines              => $args{defines},
        object_file          => $obj_file,
        include_dirs         => $self->include_dirs,
        extra_compiler_flags => $self->extra_compiler_flags,
    );

    return $obj_file;
}

sub link_c {
    my ( $self, $spec ) = @_;
    my $p = $self->{properties};

    $self->add_to_cleanup( $spec->{lib_file} );

    my $objects = $p->{objects} || [];

    return $spec->{lib_file}
      if $self->up_to_date( [ $spec->{obj_file}, @$objects ],
        $spec->{lib_file} );

    my $module_name = $spec->{module_name} || $self->module_name;

    $self->cbuilder->link(
        module_name        => $module_name,
        objects            => [ $spec->{obj_file}, @$objects ],
        lib_file           => $spec->{lib_file},
        extra_linker_flags => $p->{extra_linker_flags}
    );

    return $spec->{lib_file};
}

sub compile_xs {
    my ( $self, $file, %args ) = @_;

    $self->log_verbose("$file -> $args{outfile}\n");

    if ( eval { require ExtUtils::ParseXS; 1 } ) {

        ExtUtils::ParseXS::process_file(
            filename   => $file,
            prototypes => 0,
            output     => $args{outfile},
        );
    }
    else {

        my $xsubpp =
          Module::Build::ModuleInfo->find_module_by_name('ExtUtils::xsubpp')
          or die "Can't find ExtUtils::xsubpp in INC (@INC)";

        my @typemaps;
        push @typemaps,
          Module::Build::ModuleInfo->find_module_by_name( 'ExtUtils::typemap',
            \@INC );
        my $lib_typemap =
          Module::Build::ModuleInfo->find_module_by_name( 'typemap',
            [ File::Basename::dirname($file), File::Spec->rel2abs('.') ] );
        push @typemaps, $lib_typemap if $lib_typemap;
        @typemaps = map { +'-typemap', $_ } @typemaps;

        my $cf   = $self->{config};
        my $perl = $self->{properties}{perl};

        my @command = (
            $perl,
            "-I" . $cf->get('installarchlib'),
            "-I" . $cf->get('installprivlib'),
            $xsubpp, '-noprototypes', @typemaps, $file
        );

        $self->log_info("@command\n");
        my $fh = IO::File->new("> $args{outfile}")
          or die "Couldn't write $args{outfile}: $!";
        print {$fh} $self->_backticks(@command);
        close $fh;
    }
}

sub split_like_shell {
    my ( $self, $string ) = @_;

    return () unless defined($string);
    return @$string if UNIVERSAL::isa( $string, 'ARRAY' );
    $string =~ s/^\s+|\s+$//g;
    return () unless length($string);

    return Text::ParseWords::shellwords($string);
}

sub oneliner {

    my ( $self, $cmd, $switches, $args ) = @_;
    $switches = [] unless defined $switches;
    $args     = [] unless defined $args;

    $cmd =~ s{^\n+}{};
    $cmd =~ s{\n+$}{};

    my $perl = ref($self) ? $self->perl : $self->find_perl_interpreter;
    return $self->_quote_args( $perl, @$switches, '-e', $cmd, @$args );
}

sub run_perl_script {
    my ( $self, $script, $preargs, $postargs ) = @_;
    foreach ( $preargs, $postargs ) {
        $_ = [ $self->split_like_shell($_) ] unless ref();
    }
    return $self->run_perl_command( [ @$preargs, $script, @$postargs ] );
}

sub run_perl_command {
    my ( $self, $args ) = @_;
    $args = [ $self->split_like_shell($args) ] unless ref($args);
    my $perl = ref($self) ? $self->perl : $self->find_perl_interpreter;

    local $ENV{PERL5LIB} = join $self->config('path_sep'), $self->_added_to_INC;

    return $self->do_system( $perl, @$args );
}

sub _infer_xs_spec {
    my $self = shift;
    my $file = shift;

    my $cf = $self->{config};

    my %spec;

    my ( $v, $d, $f ) = File::Spec->splitpath($file);
    my @d = File::Spec->splitdir($d);
    ( my $file_base = $f ) =~ s/\.[^.]+$//i;

    $spec{base_name} = $file_base;

    $spec{src_dir} = File::Spec->catpath( $v, $d, '' );

    shift(@d) while @d && ( $d[0] eq 'lib' || $d[0] eq '' );
    pop(@d) while @d && $d[-1] eq '';
    $spec{module_name} = join( '::', ( @d, $file_base ) );

    $spec{archdir} =
      File::Spec->catdir( $self->blib, 'arch', 'auto', @d, $file_base );

    $spec{bs_file} = File::Spec->catfile( $spec{archdir}, "${file_base}.bs" );

    $spec{lib_file} =
      File::Spec->catfile( $spec{archdir},
        "${file_base}." . $cf->get('dlext') );

    $spec{c_file} = File::Spec->catfile( $spec{src_dir}, "${file_base}.c" );

    $spec{obj_file} =
      File::Spec->catfile( $spec{src_dir},
        "${file_base}" . $cf->get('obj_ext') );

    return \%spec;
}

sub process_xs {
    my ( $self, $file ) = @_;

    my $spec = $self->_infer_xs_spec($file);

    ( my $file_base = $file ) =~ s/\.[^.]+$//;

    $self->add_to_cleanup( $spec->{c_file} );

    unless ( $self->up_to_date( $file, $spec->{c_file} ) ) {
        $self->compile_xs( $file, outfile => $spec->{c_file} );
    }

    my $v = $self->dist_version;
    $self->compile_c( $spec->{c_file},
        defines => { VERSION => qq{"$v"}, XS_VERSION => qq{"$v"} } );

    File::Path::mkpath( $spec->{archdir}, 0, oct(777) )
      unless -d $spec->{archdir};

    $self->add_to_cleanup( $spec->{bs_file} );
    unless ( $self->up_to_date( $file, $spec->{bs_file} ) ) {
        require ExtUtils::Mkbootstrap;
        $self->log_info(
            "ExtUtils::Mkbootstrap::Mkbootstrap('$spec->{bs_file}')\n");
        ExtUtils::Mkbootstrap::Mkbootstrap( $spec->{bs_file} );
        { my $fh = IO::File->new(">> $spec->{bs_file}") } utime( (time) x 2,
            $spec->{bs_file} )
          ;
    }

    $self->link_c($spec);
}

sub do_system {
    my ( $self, @cmd ) = @_;
    $self->log_verbose("@cmd\n");

    my %seen;
    my $sep = $self->config('path_sep');
    local $ENV{PERL5LIB} = (
         !exists( $ENV{PERL5LIB} )       ? ''
        : length( $ENV{PERL5LIB} ) < 500 ? $ENV{PERL5LIB}
        : join $sep,
        grep { !$seen{$_}++ and -d $_ } split( $sep, $ENV{PERL5LIB} )
    );

    my $status = system(@cmd);
    if ( $status and $! =~ /Argument list too long/i ) {
        my $env_entries = '';
        foreach ( sort keys %ENV ) {
            $env_entries .= "$_=>" . length( $ENV{$_} ) . "; ";
        }
        warn "'Argument list' was 'too long', env lengths are $env_entries";
    }
    return !$status;
}

sub copy_if_modified {
    my $self = shift;
    my %args = (
        @_ > 3
        ? (@_)
        : ( from => shift, to_dir => shift, flatten => shift )
    );
    $args{verbose} = !$self->quiet
      unless exists $args{verbose};

    my $file = $args{from};
    unless ( defined $file and length $file ) {
        die "No 'from' parameter given to copy_if_modified";
    }

    $args{flatten} = 1 if File::Spec->file_name_is_absolute($file);

    my $to_path;
    if ( defined $args{to} and length $args{to} ) {
        $to_path = $args{to};
    }
    elsif ( defined $args{to_dir} and length $args{to_dir} ) {
        $to_path =
          File::Spec->catfile( $args{to_dir},
            $args{flatten}
            ? File::Basename::basename($file)
            : $file );
    }
    else {
        die "No 'to' or 'to_dir' parameter given to copy_if_modified";
    }

    return if $self->up_to_date( $file, $to_path );

    {
        local $self->{properties}{quiet} = 1;
        $self->delete_filetree($to_path);
    }

    File::Path::mkpath( File::Basename::dirname($to_path), 0, oct(777) );

    $self->log_verbose("Copying $file -> $to_path\n");

    if ( $^O eq 'os2' ) { chmod 0666, $to_path;
        File::Copy::syscopy( $file, $to_path, 0x1 )
          or die "Can't copy('$file', '$to_path'): $!";
    }
    else {
        File::Copy::copy( $file, $to_path )
          or die "Can't copy('$file', '$to_path'): $!";
    }

    my $mode = oct(444) | ( $self->is_executable($file) ? oct(111) : 0 );
    chmod( $mode, $to_path );

    return $to_path;
}

sub up_to_date {
    my ( $self, $source, $derived ) = @_;
    $source  = [$source]  unless ref $source;
    $derived = [$derived] unless ref $derived;

    return 0 if @$source && !@$derived || grep { not -e } @$derived;

    my $most_recent_source = time / ( 24 * 60 * 60 );
    foreach my $file (@$source) {
        unless ( -e $file ) {
            $self->log_warn(
                "Can't find source file $file for up-to-date check");
            next;
        }
        $most_recent_source = -M _ if -M _ < $most_recent_source;
    }

    foreach my $derived (@$derived) {
        return 0 if -M $derived > $most_recent_source;
    }
    return 1;
}

sub dir_contains {
    my ( $self, $first, $second ) = @_;

    ( $first, $second ) = map File::Spec->canonpath($_), ( $first, $second );
    my @first_dirs  = File::Spec->splitdir($first);
    my @second_dirs = File::Spec->splitdir($second);

    return 0 if @second_dirs < @first_dirs;

    my $is_same = (
        $self->_case_tolerant
        ? sub { lc( shift() ) eq lc( shift() ) }
        : sub { shift()       eq shift() }
    );

    while (@first_dirs) {
        return 0 unless $is_same->( shift @first_dirs, shift @second_dirs );
    }

    return 1;
}

1;
__END__


