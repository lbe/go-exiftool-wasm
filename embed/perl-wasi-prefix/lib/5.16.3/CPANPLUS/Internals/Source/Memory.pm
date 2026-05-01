package CPANPLUS::Internals::Source::Memory;

use base 'CPANPLUS::Internals::Source';

use strict;

use CPANPLUS::Error;
use CPANPLUS::Module;
use CPANPLUS::Module::Fake;
use CPANPLUS::Module::Author;
use CPANPLUS::Internals::Constants;

use File::Fetch;
use Archive::Extract;

use IPC::Cmd qw[can_run];
use File::Temp qw[tempdir];
use File::Basename qw[dirname];
use Params::Check qw[allow check];
use Module::Load::Conditional qw[can_load];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

$Params::Check::VERBOSE = 1;


{
    my $from_storable;

    sub _init_trees {
        my $self = shift;
        my $conf = $self->configure_object;
        my %hash = @_;

        my ( $path, $uptodate, $verbose, $use_stored );
        my $tmpl = {
            path => { default => $conf->get_conf('base'), store => \$path },
            verbose =>
              { default => $conf->get_conf('verbose'), store => \$verbose },
            uptodate   => { required => 1, store => \$uptodate },
            use_stored => { default  => 1, store => \$use_stored },
        };

        check( $tmpl, \%hash ) or return;

        my $stored = $self->__memory_retrieve_source(
            path     => $path,
            uptodate => $uptodate && $use_stored,
            verbose  => $verbose,
        ) || {};

        $from_storable = keys %$stored ? 1 : 0;

        $self->_atree( $stored->{_atree} || {} );
        $self->_mtree( $stored->{_mtree} || {} );

        return 1;
    }

    sub _standard_trees_completed { return $from_storable }
    sub _custom_trees_completed   { return $from_storable }

    sub _finalize_trees {
        my $self = shift;
        my $conf = $self->configure_object;
        my %hash = @_;

        my ( $path, $uptodate, $verbose );
        my $tmpl = {
            path => { default => $conf->get_conf('base'), store => \$path },
            verbose =>
              { default => $conf->get_conf('verbose'), store => \$verbose },
            uptodate => { required => 1, store => \$uptodate },
        };

        {
            local $Params::Check::ALLOW_UNKNOWN = 1;
            check( $tmpl, \%hash ) or return;
        }

        $self->__memory_save_source() if !$uptodate or not $from_storable;

        return 1;
    }

    sub _save_state {
        my $self = shift;
        return $self->_finalize_trees( @_, uptodate => 0 );
    }
}

sub _add_author_object {
    my $self = shift;
    my %hash = @_;

    my $class;
    my $tmpl = {
        class => { default => 'CPANPLUS::Module::Author', store => \$class },
        map { $_ => { required => 1 } } qw[ author cpanid email ]
    };

    my $href = do {
        local $Params::Check::NO_DUPLICATES = 1;
        check( $tmpl, \%hash ) or return;
    };

    my $obj = $class->new( %$href, _id => $self->_id );

    $self->author_tree->{ $href->{'cpanid'} } = $obj or return;

    return $obj;
}

sub _add_module_object {
    my $self = shift;
    my %hash = @_;

    my $class;
    my $tmpl = {
        class => { default => 'CPANPLUS::Module', store => \$class },
        map { $_ => { required => 1 } }
          qw[ module version path comment author package description dslip mtime ]
    };

    my $href = do {
        local $Params::Check::NO_DUPLICATES = 1;
        check( $tmpl, \%hash ) or return;
    };

    my $obj = $class->new( %$href, _id => $self->_id );

    $self->module_tree->{ $href->{module} } = $obj or return;

    return $obj;
}

{
    my %map = (
        _source_search_module_tree => [ module_tree => 'CPANPLUS::Module' ],
        _source_search_author_tree =>
          [ author_tree => 'CPANPLUS::Module::Author' ],
    );

    while ( my ( $sub, $aref ) = each %map ) {
        no strict 'refs';

        my ( $meth, $class ) = @$aref;

        *$sub = sub {
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
                    allow    => [ $class->accessors() ],
                    store    => \$type
                },
            };

            my $args = check( $tmpl, \%hash ) or return;

            my @rv;
            for my $obj ( values %{ $self->$meth } ) {
                push @rv, $obj if allow( $obj->$type() => $list );
            }

            return @rv;
          }
    }
}


sub __memory_retrieve_source {
    my $self = shift;
    my %hash = @_;
    my $conf = $self->configure_object;

    my $tmpl = {
        path     => { default => $conf->get_conf('base') },
        verbose  => { default => $conf->get_conf('verbose') },
        uptodate => { default => 0 },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $storable = can_load( modules => { 'Storable' => '0.0' } )
      if $conf->get_conf('storable');

    return unless $storable;

    my $stored = $self->__memory_storable_file( $args->{path} );

    if ( $storable && -e $stored && -s _ && $args->{'uptodate'} ) {
        msg( loc( "Retrieving %1", $stored ), $args->{'verbose'} );

        my $href = Storable::retrieve($stored);
        return $href;
    }
    else {
        return;
    }
}


sub __memory_save_source {
    my $self = shift;
    my %hash = @_;
    my $conf = $self->configure_object;

    my $tmpl = {
        path => { default => $conf->get_conf('base'), allow => DIR_EXISTS },
        verbose => { default => $conf->get_conf('verbose') },
        force   => { default => 1 },
    };

    my $args = check( $tmpl, \%hash ) or return;

    my $aref = [qw[_mtree _atree]];

    my $storable;
    $storable = can_load( modules => { 'Storable' => '0.0' } )
      if $conf->get_conf('storable');
    return unless $storable;

    my $to_write = {};
    foreach my $key (@$aref) {
        next unless ref( $self->$key );
        $to_write->{$key} = $self->$key;
    }

    return unless keys %$to_write;

    my $stored = $self->__memory_storable_file( $args->{path} );

    if ( -e $stored && not -w $stored ) {
        msg( loc( "%1 not writable; skipped.", $stored ), $args->{'verbose'} );
        return;
    }

    msg(
        loc(
"Writing compiled source information to disk. This might take a little while."
        ),
        $args->{'verbose'}
    );

    my $flag;
    unless ( Storable::nstore( $to_write, $stored ) ) {
        error( loc( "could not store %1!", $stored ) );
        $flag++;
    }

    return $flag ? 0 : 1;
}

sub __memory_storable_file {
    my $self = shift;
    my $conf = $self->configure_object;
    my $path = shift or return;

    my $storable =
      $conf->get_conf('storable')
      ? can_load( modules => { 'Storable' => '0.0' } )
      : 0;

    return unless $storable;

    my $stored = File::Spec->rel2abs(
        File::Spec->catfile(
                $path, $conf->_get_source('stored')
              . '.s'
              . $Storable::VERSION
              . '.c'
              . $self->VERSION
              . STORABLE_EXT )
    );

    return $stored;
}

1;
