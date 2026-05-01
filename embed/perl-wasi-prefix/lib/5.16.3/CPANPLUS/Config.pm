package CPANPLUS::Config;

use strict;
use warnings;

use base 'Object::Accessor';

use base 'CPANPLUS::Internals::Utils';

use Config;
use File::Spec;
use Module::Load;
use CPANPLUS;
use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;

use File::Basename qw[dirname];
use IPC::Cmd qw[can_run];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';
use Module::Load::Conditional qw[check_install];
use version;


my $Conf = {
    '_fetch' => { 'blacklist' => ['ftp'], },

    '_source' => {
        'hosts'        => 'MIRRORED.BY',
        'auth'         => '01mailrc.txt.gz',
        'stored'       => 'sourcefiles',
        'dslip'        => '03modlist.data.gz',
        'update'       => '86400',
        'mod'          => '02packages.details.txt.gz',
        'custom_index' => 'packages.txt',
    },
    '_build' => {
        'plugins'           => 'plugins',
        'moddir'            => 'build',
        'startdir'          => '',
        'distdir'           => 'dist',
        'autobundle'        => 'autobundle',
        'autobundle_prefix' => 'Snapshot',
        'autdir'            => 'authors',
        'install_log_dir'   => 'install-logs',
        'custom_sources'    => 'custom-sources',
        'sanity_check'      => 1,
    },
    '_mirror' => {
        'base'  => 'authors/id/',
        'auth'  => 'authors/01mailrc.txt.gz',
        'dslip' => 'modules/03modlist.data.gz',
        'mod'   => 'modules/02packages.details.txt.gz'
    },
};


$Conf->{'conf'}->{'hosts'} = [
    {
        'scheme' => 'ftp',
        'path'   => '/pub/CPAN/',
        'host'   => 'ftp.cpan.org'
    },
    {
        'scheme' => 'http',
        'path'   => '/',
        'host'   => 'www.cpan.org'
    },
    {
        'scheme' => 'ftp',
        'path'   => '/',
        'host'   => 'cpan.hexten.net'
    },
    {
        'scheme' => 'ftp',
        'path'   => '/CPAN/',
        'host'   => 'cpan.cpantesters.org'
    },
    {
        'scheme' => 'ftp',
        'path'   => '/pub/languages/perl/CPAN/',
        'host'   => 'ftp.funet.fi'
    }
];


$Conf->{'conf'}->{'allow_build_interactivity'} = 1;


$Conf->{'conf'}->{'allow_unknown_prereqs'} = 1;


$Conf->{'conf'}->{'base'} =
  File::Spec->catdir( __PACKAGE__->_home_dir, DOT_CPANPLUS );


$Conf->{'conf'}->{'buildflags'} = '';


$Conf->{'conf'}->{'cpantest'} = 0;


$Conf->{'conf'}->{'cpantest_mx'} = '';


$Conf->{'conf'}->{'debug'} = 0;


$Conf->{'conf'}->{'dist_type'} = '';


$Conf->{'conf'}->{'email'} = DEFAULT_EMAIL;


$Conf->{'conf'}->{'enable_custom_sources'} = 1;


$Conf->{'conf'}->{'extractdir'} = '';


$Conf->{'conf'}->{'fetchdir'} = '';


$Conf->{'conf'}->{'flush'} = 1;


$Conf->{'conf'}->{'force'} = 0;


$Conf->{'conf'}->{'lib'} = [];


$Conf->{'conf'}->{'makeflags'} = '';


$Conf->{'conf'}->{'makemakerflags'} = '';


$Conf->{'conf'}->{'md5'} = ( check_install( module => 'Digest::SHA' ) ? 1 : 0 );


$Conf->{'conf'}->{'no_update'} = 0;


$Conf->{'conf'}->{'passive'} = 1;


$Conf->{'conf'}->{'prefer_bin'} =
  ( eval { require Compress::Zlib; 1 } ? 0 : 1 );


$Conf->{'conf'}->{'prefer_makefile'} = (
    $] >= 5.010001
      or (  check_install( module => 'Module::Build', version => '0.32' )
        and check_install( module => INSTALLER_BUILD, version => '0.60' ) )
    ? 0
    : 1
);


$Conf->{'conf'}->{'prereqs'} = PREREQ_ASK;


$Conf->{'conf'}->{'shell'} = 'CPANPLUS::Shell::Default';


$Conf->{'conf'}->{'show_startup_tip'} = 1;


$Conf->{'conf'}->{'signature'} = do {
    check_install( module => 'Module::Signature', version => '0.06' )
      and (can_run('gpg')
        || check_install( module => 'Crypt::OpenPGP' ) );
  }
  ? 1 : 0;


$Conf->{'conf'}->{'skiptest'} = 0;


$Conf->{'conf'}->{'storable'} =
  ( check_install( module => 'Storable' ) ? 1 : 0 );


$Conf->{'conf'}->{'timeout'} = 300;


$Conf->{'conf'}->{'verbose'} = $ENV{PERL5_CPANPLUS_VERBOSE} || 0;


$Conf->{'conf'}->{'write_install_logs'} = 1;


$Conf->{'conf'}->{'source_engine'} = DEFAULT_SOURCE_ENGINE;


$Conf->{'conf'}->{'cpantest_reporter_args'} = {};



$Conf->{'program'}->{'editor'} = do {
         $ENV{'EDITOR'}
      || $ENV{'VISUAL'}
      || can_run('vi')
      || can_run('pico');
};


$Conf->{'program'}->{'make'} = can_run( $Config{'make'} ) || can_run('make');


$Conf->{'program'}->{'pager'} =
  $ENV{'PAGER'} || can_run('less') || can_run('more');


$Conf->{'program'}->{'shell'} =
    $^O eq 'MSWin32'
  ? $ENV{COMSPEC}
  : $ENV{SHELL};


$Conf->{'program'}->{'sudo'} = do {
    my $sudo = undef;

    if ($>) {

        if ( -w $Config{'installsitelib'} && -w $Config{'installsitebin'} ) {

            if ( defined $Config{'installsiteman3dir'} ) {
                $sudo =
                  -w $Config{'installsiteman3dir'}
                  ? undef
                  : can_run('sudo');
            }
            else {
                $sudo = undef;
            }

        }
        elsif ( $ENV{'PERL_MM_OPT'}
            and $ENV{'PERL_MM_OPT'} =~ /INSTALL|LIB|PREFIX/ )
        {
            $sudo = undef;

        }
        else {
            $sudo = can_run('sudo');
        }
    }

    $sudo;
};


$Conf->{'program'}->{'perlwrapper'} = sub {
    my $name = 'cpanp-run-perl';

    my @bins = do {
        require Config;
        my $ver = $Config::Config{version};

        $Config::Config{versiononly}
          ? ( $name . $ver, $name )
          : ( $name, $name . $ver );
    };

    @bins = map { $_, "$_.bat" } @bins if $^O eq 'MSWin32';

    my $path;
  BIN: for my $bin (@bins) {

        my $maybe =
          File::Spec->rel2abs( File::Spec->catfile( dirname($0), $bin ) );
        $path = $maybe and last BIN if -f $maybe;

        $maybe = File::Spec->rel2abs(
            File::Spec->catfile(
                dirname( $INC{'CPANPLUS.pm'} ),
                '..', 'bin', $bin, )
        );
        $path = $maybe and last BIN if -f $maybe;

        $maybe = File::Spec->rel2abs(
            File::Spec->catfile(
                dirname( $INC{'CPANPLUS.pm'} ),
                '..', '..', '..', '..', 'bin', $bin, )
        );
        $path = $maybe and last BIN if -f $maybe;

        for my $dir (
            File::Spec->rel2abs( dirname($^X) ),
            split( /\Q$Config::Config{path_sep}\E/, $ENV{PATH} ),
            File::Spec->curdir,
          )
        {

            $dir = VMS::Filespec::vmspath($dir) if ON_VMS;

            $maybe = File::Spec->catfile( $dir, $bin );
            $path = $maybe and last BIN if -f $maybe;
        }
    }

    return $path if defined $path;

    my $cpdb = check_install( module => INSTALLER_BUILD );
    return ''
      unless $cpdb
      and eval { version->parse( $cpdb->{version} ) < version->parse('0.60') };

    error(
        loc(
            "Could not find the '%1' binary in your path"
              . "--this may be a problem.\n"
              . "Please locate this program and set "
              . "your '%2' config entry to its path.\n"
              . "From the default shell, you can do this by typing:\n\n"
              . "  %3\n"
              . "  %4\n",
            $name,
            'perlwrapper',
            's program perlwrapper FULL_PATH_TO_CPANP_RUN_PERL',
            's save'
        )
    );
    return '';
  }
  ->();


sub new {
    my $class = shift;
    my $obj   = $class->SUPER::new;

    $obj->mk_accessors( keys %$Conf );

    for my $acc ( keys %$Conf ) {
        my $subobj = Object::Accessor->new;
        $subobj->mk_accessors( keys %{ $Conf->{$acc} } );

        for my $subacc ( $subobj->ls_accessors ) {
            $subobj->$subacc( $Conf->{$acc}->{$subacc} );
        }

        $obj->$acc($subobj);
    }

    $obj->_clean_up_paths;

    $IPC::Cmd::WARN = 0;

    return $obj;
}

sub _clean_up_paths {
    my $self = shift;

    if ( $^O eq 'MSWin32' ) {
        for my $pgm ( $self->program->ls_accessors ) {
            my $path = $self->program->$pgm;

            if ( $path and $path =~ /\s+/ ) {
                my ( $prog, $args );

                if ( $path =~ /^(.*?)(\s+\/.*$)/ ) {
                    ( $prog, $args ) = ( $1, $2 );

                }
                else {
                    ( $prog, $args ) = ( $path, '' );
                }

                $prog = Win32::GetShortPathName($prog);
                $self->program->$pgm( $prog . $args );
            }
        }
    }

    return 1;
}

1;


