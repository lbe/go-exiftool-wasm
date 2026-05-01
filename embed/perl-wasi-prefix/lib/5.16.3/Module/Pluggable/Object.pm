package Module::Pluggable::Object;

use strict;
use File::Find ();
use File::Basename;
use File::Spec::Functions qw(splitdir catdir curdir catfile abs2rel);
use Carp qw(croak carp);
use Devel::InnerPackage;
use vars qw($VERSION);

$VERSION = '3.9';

sub new {
    my $class = shift;
    my %opts  = @_;

    return bless \%opts, $class;

}

sub plugins {
    my $self = shift;

    $self->{'require'} = 1 if $self->{'inner'};

    my $filename = $self->{'filename'};
    my $pkg      = $self->{'package'};

    $self->_setup_exceptions;

    for (qw(search_path search_dirs)) {
        $self->{$_} = [ $self->{$_} ]
          if exists $self->{$_} && !ref( $self->{$_} );
    }

    $self->{'search_path'} = ["${pkg}::Plugin"] unless $self->{'search_path'};

    my @SEARCHDIR =
         exists $INC{"blib.pm"}
      && defined $filename
      && $filename =~ m!(^|/)blib/! ? grep { /blib/ } @INC : @INC;

    unshift @SEARCHDIR, @{ $self->{'search_dirs'} }
      if defined $self->{'search_dirs'};

    my @plugins = $self->search_directories(@SEARCHDIR);
    push( @plugins, $self->handle_innerpackages($_) )
      for @{ $self->{'search_path'} };

    return () unless @plugins;

    my %plugins;
    for (@plugins) {
        next unless $self->_is_legit($_);
        $plugins{$_} = 1;
    }

    if ( defined $self->{'instantiate'} ) {
        my $method = $self->{'instantiate'};
        return
          map { ( $_->can($method) ) ? $_->$method(@_) : () } keys %plugins;
    }
    else {
        return keys %plugins;
    }

}

sub _setup_exceptions {
    my $self = shift;

    my %only;
    my %except;
    my $only;
    my $except;

    if ( defined $self->{'only'} ) {
        if ( ref( $self->{'only'} ) eq 'ARRAY' ) {
            %only = map { $_ => 1 } @{ $self->{'only'} };
        }
        elsif ( ref( $self->{'only'} ) eq 'Regexp' ) {
            $only = $self->{'only'};
        }
        elsif ( ref( $self->{'only'} ) eq '' ) {
            $only{ $self->{'only'} } = 1;
        }
    }

    if ( defined $self->{'except'} ) {
        if ( ref( $self->{'except'} ) eq 'ARRAY' ) {
            %except = map { $_ => 1 } @{ $self->{'except'} };
        }
        elsif ( ref( $self->{'except'} ) eq 'Regexp' ) {
            $except = $self->{'except'};
        }
        elsif ( ref( $self->{'except'} ) eq '' ) {
            $except{ $self->{'except'} } = 1;
        }
    }
    $self->{_exceptions}->{only_hash}   = \%only;
    $self->{_exceptions}->{only}        = $only;
    $self->{_exceptions}->{except_hash} = \%except;
    $self->{_exceptions}->{except}      = $except;

}

sub _is_legit {
    my $self   = shift;
    my $plugin = shift;
    my %only   = %{ $self->{_exceptions}->{only_hash} || {} };
    my %except = %{ $self->{_exceptions}->{except_hash} || {} };
    my $only   = $self->{_exceptions}->{only};
    my $except = $self->{_exceptions}->{except};

    return 0 if ( keys %only && !$only{$plugin} );
    return 0 unless ( !defined $only || $plugin =~ m!$only! );

    return 0 if ( keys %except && $except{$plugin} );
    return 0 if ( defined $except && $plugin =~ m!$except! );

    return 1;
}

sub search_directories {
    my $self      = shift;
    my @SEARCHDIR = @_;

    my @plugins;
    foreach my $dir (@SEARCHDIR) {
        push @plugins, $self->search_paths($dir);
    }
    return @plugins;
}

sub search_paths {
    my $self = shift;
    my $dir  = shift;
    my @plugins;

    my $file_regex = $self->{'file_regex'} || qr/\.pm$/;

    foreach my $searchpath ( @{ $self->{'search_path'} } ) {
        my $sp = catdir( $dir, ( split /::/, $searchpath ) );

        next unless ( -e $sp && -d _ );

        my @files = $self->find_files($sp);

        foreach my $file (@files) {
            next unless ($file) = ( $file =~ /(.*$file_regex)$/ );
            my ( $name, $directory, $suffix ) = fileparse( $file, $file_regex );

            next
              if (!$self->{include_editor_junk}
                && $self->_is_editor_junk($name) );

            $directory = abs2rel( $directory, $sp );

            my @pkg_dirs = ();
            if ( $name eq lc($name) || $name eq uc($name) ) {
                my $pkg_file = catfile( $sp, $directory, "$name$suffix" );
                open PKGFILE, "<$pkg_file"
                  or die "search_paths: Can't open $pkg_file: $!";
                my $in_pod = 0;
                while ( my $line = <PKGFILE> ) {
                    $in_pod = 1 if $line =~ m/^=\w/;
                    $in_pod = 0 if $line =~ /^=cut/;
                    next if ( $in_pod || $line =~ /^=cut/ );
                    next if $line =~ /^\s*#/;
                    if ( $line =~ m/^\s*package\s+(.*::)?($name)\s*;/i ) {
                        @pkg_dirs = split /::/, $1;
                        $name = $2;
                        last;
                    }
                }
                close PKGFILE;
            }

            $directory =~ s/^[a-z]://i if ( $^O =~ /MSWin32|dos/ );
            my @dirs = ();
            if ($directory) {
                ($directory) = ( $directory =~ /(.*)/ );
                @dirs = grep( length($_), splitdir($directory) )
                  unless $directory eq curdir();
                for my $d ( reverse @dirs ) {
                    my $pkg_dir = pop @pkg_dirs;
                    last unless defined $pkg_dir;
                    $d =~ s/\Q$pkg_dir\E/$pkg_dir/i;
                }
            }
            else {
                $directory = "";
            }
            my $plugin = join '::', $searchpath, @dirs, $name;

            next unless $plugin =~ m!(?:[a-z\d]+)[a-z\d]!i;

            my $err = $self->handle_finding_plugin($plugin);
            carp "Couldn't require $plugin : $err" if $err;

            push @plugins, $plugin;
        }

        push @plugins, $self->handle_innerpackages($searchpath);
    }

    return @plugins;
}

sub _is_editor_junk {
    my $self = shift;
    my $name = shift;

    return 1 if $name =~ /~$/;
    return 1 if $name =~ /^\.#/;
    return 1 if $name =~ /\.sw[po]$/;

    return 0;
}

sub handle_finding_plugin {
    my $self   = shift;
    my $plugin = shift;

    return unless ( defined $self->{'instantiate'} || $self->{'require'} );
    return unless $self->_is_legit($plugin);
    $self->_require($plugin);
}

sub find_files {
    my $self        = shift;
    my $search_path = shift;
    my $file_regex  = $self->{'file_regex'} || qr/\.pm$/;

    my @files = ();
    { local $_;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return unless $File::Find::name =~ /$file_regex/;
                    ( my $path = $File::Find::name ) =~ s#^\\./##;
                    push @files, $path;
                  }
            },
            $search_path
        );
    }
    return @files;

}

sub handle_innerpackages {
    my $self = shift;
    return () if ( exists $self->{inner} && !$self->{inner} );

    my $path = shift;
    my @plugins;

    foreach my $plugin ( Devel::InnerPackage::list_packages($path) ) {
        my $err = $self->handle_finding_plugin($plugin);
        push @plugins, $plugin;
    }
    return @plugins;

}

sub _require {
    my $self = shift;
    my $pack = shift;
    local $@;
    eval "CORE::require $pack";
    return $@;
}

1;


