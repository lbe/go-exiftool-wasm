package CPANPLUS::Internals::Search;

use strict;

use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;
use CPANPLUS::Module;
use CPANPLUS::Module::Author;

use File::Find;
use File::Spec;

use Params::Check qw[check allow];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

$Params::Check::VERBOSE = 1;


sub _search_module_tree {

    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my ( $mods, $list, $verbose, $type );
    my $tmpl = {
        data => {
            default     => [],
            strict_type => 1,
            store       => \$mods
        },
        allow => {
            required    => 1,
            default     => [],
            strict_type => 1,
            store       => \$list
        },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        type => {
            required => 1,
            allow    => [ CPANPLUS::Module->accessors() ],
            store    => \$type
        },
    };

    my $args = do {
        local $Params::Check::SANITY_CHECK_TEMPLATE = 0;

        check( $tmpl, \%hash );
      }
      or return;

    if (@$mods) {
        local $Params::Check::VERBOSE = 0;

        my @rv;
        for my $mod (@$mods) {
            push @rv, $mod if allow( $mod->$type() => $list );

        }
        return \@rv;

    }
    else {
        my @rv = $self->_source_search_module_tree(
            allow => $list,
            type  => $type,
        );
        return \@rv;
    }
}


sub _search_author_tree {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my ( $authors, $list, $verbose, $type );
    my $tmpl = {
        data => {
            default     => [],
            strict_type => 1,
            store       => \$authors
        },
        allow => {
            required    => 1,
            default     => [],
            strict_type => 1,
            store       => \$list
        },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        type => {
            required => 1,
            allow    => [ CPANPLUS::Module::Author->accessors() ],
            store    => \$type
        },
    };

    my $args = check( $tmpl, \%hash ) or return;

    if (@$authors) {
        local $Params::Check::VERBOSE = 0;

        my @rv;
        for my $auth (@$authors) {
            push @rv, $auth if allow( $auth->$type() => $list );
        }
        return \@rv;
    }
    else {
        my @rv = $self->_source_search_author_tree(
            allow => $list,
            type  => $type,
        );
        return \@rv;
    }
}


sub _all_installed {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my %find_args = ( follow_skip => 2 );

    $find_args{'follow_fast'} = 1 unless ON_WIN32;

    my %seen;
    my @rv;
    for my $dir (@INC) {
        next if $dir eq '.';

        next unless -d $dir;

        $dir = File::Spec->canonpath($dir) unless ON_VMS;

        my $file_spec = ON_VMS ? 'File::Spec::Unix' : 'File::Spec';

        eval {
            File::Find::find(
                {
                    %find_args,
                    wanted => sub {

                        return unless /\.pm$/i;
                        my $mod = $File::Find::name;

                        $mod = VMS::Filespec::unixify($mod) if ON_VMS;

                        $mod = substr( $mod, length($dir) + 1, -3 );
                        $mod = join '::', $file_spec->splitdir($mod);

                        return if $seen{$mod}++;

                        my $modobj = $self->module_tree($mod);

                        return unless $modobj;

                        push @rv, $modobj;
                    },
                },
                $dir
            );
        };

        error( loc( "Error finding installed files in '%1': %2", $dir, $@ ) )
          if $@;
    }

    return \@rv;
}

1;

