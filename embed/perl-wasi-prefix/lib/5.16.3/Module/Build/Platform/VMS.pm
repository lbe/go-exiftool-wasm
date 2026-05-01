package Module::Build::Platform::VMS;

use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;
use Module::Build::Base;
use Config;

use vars qw(@ISA);
@ISA = qw(Module::Build::Base);


sub _set_defaults {
    my $self = shift;
    $self->SUPER::_set_defaults(@_);

    $self->{properties}{build_script} = 'Build.com';
}


sub cull_args {
    my $self = shift;
    my ( $action, $args ) = $self->SUPER::cull_args(@_);
    my @possible_actions = grep { lc $_ eq lc $action } $self->known_actions;

    die "Ambiguous action '$action'.  Could be one of @possible_actions"
      if @possible_actions > 1;

    return ( $possible_actions[0], $args );
}


sub manpage_separator {
    return '__';
}


sub _catprefix {
    my ( $self, $rprefix, $default ) = @_;

    my ( $rvol, $rdirs ) = File::Spec->splitpath($rprefix);
    if ($rvol) {
        return File::Spec->catpath( $rvol,
            File::Spec->catdir( $rdirs, $default ), '' );
    }
    else {
        return File::Spec->catdir( $rdirs, $default );
    }
}

sub _prefixify {
    my ( $self, $path, $sprefix, $type ) = @_;
    my $rprefix = $self->prefix;

    return '' unless defined $path;

    $self->log_verbose("  prefixify $path from $sprefix to $rprefix\n");

    $rprefix = VMS::Filespec::vmspath($rprefix) if $rprefix;
    $sprefix = VMS::Filespec::vmspath($sprefix) if $sprefix;

    $self->log_verbose( "  rprefix translated to $rprefix\n"
          . "  sprefix translated to $sprefix\n" );

    if ( length($path) == 0 ) {
        $self->log_verbose("  no path to prefixify.\n");
    }
    elsif ( !File::Spec->file_name_is_absolute($path) ) {
        $self->log_verbose("    path is relative, not prefixifying.\n");
    }
    elsif ( $sprefix eq $rprefix ) {
        $self->log_verbose("  no new prefix.\n");
    }
    else {
        my ( $path_vol, $path_dirs ) = File::Spec->splitpath($path);
        my $vms_prefix = $self->config('vms_prefix');
        if ( $path_vol eq $vms_prefix . ':' ) {
            $self->log_verbose("  $vms_prefix: seen\n");

            $path_dirs =~ s{^\[}{\[.} unless $path_dirs =~ m{^\[\.};
            $path = $self->_catprefix( $rprefix, $path_dirs );
        }
        else {
            $self->log_verbose("    cannot prefixify.\n");
            return $self->prefix_relpaths( $self->installdirs, $type );
        }
    }

    $self->log_verbose("    now $path\n");

    return $path;
}


sub _quote_args {
    my ( $self, @args ) = @_;
    my $got_arrayref =
      ( scalar(@args) == 1 && UNIVERSAL::isa( $args[0], 'ARRAY' ) )
      ? 1
      : 0;

    map {
        if ( !/^\// ) {
            $_ =~ s/\"/""/g;
            $_ = q(") . $_ . q(");
        }
      } (
        $got_arrayref
        ? @{ $args[0] }
        : @args
      );

    return $got_arrayref
      ? $args[0]
      : join( ' ', @args );
}


sub have_forkpipe { 0 }


sub _backticks {
    my ( $self, @cmd ) = @_;
    my $cmd  = shift @cmd;
    my $args = $self->_quote_args(@cmd);
    return `$cmd $args`;
}


sub find_command {
    my ( $self, $command ) = @_;

    if ( $^O eq 'VMS' ) {
        require VMS::DCLsym;
        my $syms = VMS::DCLsym->new;
        return $command if scalar $syms->getsym( uc $command );
    }

    $self->SUPER::find_command($command);
}


sub _maybe_command {
    my ( $self, $file ) = @_;
    return $file if -x $file && !-d _;
    my (@dirs) = ('');
    my (@exts) = ( '', $Config{'exe_ext'}, '.exe', '.com' );

    if ( $file !~ m![/:>\]]! ) {
        for ( my $i = 0 ; defined $ENV{"DCL\$PATH;$i"} ; $i++ ) {
            my $dir = $ENV{"DCL\$PATH;$i"};
            $dir .= ':' unless $dir =~ m%[\]:]$%;
            push( @dirs, $dir );
        }
        push( @dirs, 'Sys$System:' );
        foreach my $dir (@dirs) {
            my $sysfile = "$dir$file";
            foreach my $ext (@exts) {
                return $file if -x "$sysfile$ext" && !-d _;
            }
        }
    }
    return;
}


sub do_system {
    my ( $self, @cmd ) = @_;
    $self->log_verbose("@cmd\n");
    my $cmd  = shift @cmd;
    my $args = $self->_quote_args(@cmd);
    return !system("$cmd $args");
}


sub oneliner {
    my $self     = shift;
    my $oneliner = $self->SUPER::oneliner(@_);

    $oneliner =~ s/^\"\S+\"//;

    return "MCR $^X $oneliner";
}


sub _infer_xs_spec {
    my $self = shift;
    my $file = shift;

    my $spec = $self->SUPER::_infer_xs_spec($file);

    if ( defined &DynaLoader::mod2fname ) {
        my $file = $$spec{module_name} . '.' . $self->{config}->get('dlext');
        $file =~ tr/:/_/;
        $file = DynaLoader::mod2fname( [$file] );
        $$spec{lib_file} = File::Spec->catfile( $$spec{archdir}, $file );
    }

    return $spec;
}


sub rscan_dir {
    my ( $self, $dir, $pattern ) = @_;

    my $result = $self->SUPER::rscan_dir( $dir, $pattern );

    for my $file (@$result) {
        if ( !_efs() && ( $file =~ m#/# ) ) {
            $file =~ s/\.$//;
        }
    }
    return $result;
}


sub dist_dir {
    my $self = shift;

    my $dist_dir = $self->SUPER::dist_dir;
    $dist_dir =~ s/\./_/g unless _efs();
    return $dist_dir;
}


sub man3page_name {
    my $self = shift;

    my $mpname = $self->SUPER::man3page_name(shift);
    my $sep    = $self->manpage_separator;
    $mpname =~ s/^$sep//;
    return $mpname;
}


sub expand_test_dir {
    my ( $self, $dir ) = @_;

    my @reldirs = $self->SUPER::expand_test_dir($dir);

    for my $eachdir (@reldirs) {
        my ( $v, $d, $f ) = File::Spec->splitpath($eachdir);
        my $reldir = File::Spec->abs2rel( File::Spec->catpath( $v, $d, '' ) );
        $eachdir = File::Spec->catfile( $reldir, $f );
    }
    return @reldirs;
}


sub _detildefy {
    my ( $self, $arg ) = @_;

    return $arg if ( $arg =~ /^~~/ );

    return $arg if ( $arg =~ /^~ / );

    if ( $arg =~ /^~/ ) {
        my $spec = $arg;

        $spec =~ s/^~//;

        $spec =~ s#^/##;

        my $home = VMS::Filespec::unixify( $ENV{HOME} );

        $home .= '/' unless $home =~ m#/$#;

        if ( $spec eq '' ) {
            $home =~ s#/$##;
            return $home;
        }

        my ( $hvol, $hdir, $hfile ) = File::Spec::Unix->splitpath($home);
        if ( $hdir eq '' ) {
            $hdir = $hfile;
        }

        my ( $vol, $dir, $file ) = File::Spec::Unix->splitpath($spec);

        my @hdirs = File::Spec::Unix->splitdir($hdir);
        my @dirs  = File::Spec::Unix->splitdir($dir);

        my $newdirs;

        if ( $arg =~ m#^~/# ) {

            $newdirs = File::Spec::Unix->catdir( @hdirs, @dirs );

        }
        else {

            my @backup = File::Spec::Unix->splitdir( File::Spec::Unix->updir );

            $newdirs = File::Spec::Unix->catdir( @hdirs, @backup, @dirs );

        }

        $arg = File::Spec::Unix->catpath( $hvol, $newdirs, $file );

    }
    return $arg;

}


sub find_perl_interpreter {
    return VMS::Filespec::vmsify($^X);
}


sub localize_file_path {
    my ( $self, $path ) = @_;
    $path = VMS::Filespec::vmsify($path);
    $path =~ s/\.\z//;
    return $path;
}


sub localize_dir_path {
    my ( $self, $path ) = @_;
    return VMS::Filespec::vmspath($path);
}


sub ACTION_clean {
    my ($self) = @_;
    foreach my $item ( map glob( VMS::Filespec::rmsexpand( $_, '.;0' ) ),
        $self->cleanup )
    {
        $self->delete_filetree($item);
    }
}

my $use_feature;

BEGIN {
    if ( eval { local $SIG{__DIE__}; require VMS::Feature; } ) {
        $use_feature = 1;
    }
}

sub _unix_rpt {
    my $unix_rpt;
    if ($use_feature) {
        $unix_rpt = VMS::Feature::current("filename_unix_report");
    }
    else {
        my $env_unix_rpt = $ENV{'DECC$FILENAME_UNIX_REPORT'} || '';
        $unix_rpt = $env_unix_rpt =~ /^[ET1]/i;
    }
    return $unix_rpt;
}

sub _efs {
    my $efs;
    if ($use_feature) {
        $efs = VMS::Feature::current("efs_charset");
    }
    else {
        my $env_efs = $ENV{'DECC$EFS_CHARSET'} || '';
        $efs = $env_efs =~ /^[ET1]/i;
    }
    return $efs;
}


1;
__END__
