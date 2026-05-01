package CPANPLUS::Module::Author;

use strict;

use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;
use Params::Check qw[check];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';

local $Params::Check::VERBOSE = 1;


my $tmpl = {
    author => { required => 1 }, cpanid => { required => 1 }, email =>
      { default => '' }, _id => { required => 1 }, };

for my $key ( keys %$tmpl ) {
    no strict 'refs';
    *{ __PACKAGE__ . "::$key" } = sub {
        my $self = shift;
        $self->{$key} = $_[0] if @_;
        return $self->{$key};
      }
}

sub parent {
    my $self = shift;
    my $obj  = CPANPLUS::Internals->_retrieve_id( $self->_id );

    return $obj;
}


sub new {
    my $class = shift;
    my %hash  = @_;

    local $Params::Check::SANITY_CHECK_TEMPLATE = 0;

    my $object = check( $tmpl, \%hash ) or return;

    return bless $object, $class;
}


sub modules {
    my $self = shift;
    my $cb   = $self->parent;

    my $aref = $cb->_search_module_tree(
        type  => 'author',
        allow => [ $self, $self->cpanid ],
    );
    return @$aref if $aref;
    return;
}


sub distributions {
    my $self = shift;
    my %hash = @_;

    local $Params::Check::ALLOW_UNKNOWN = 1;
    local $Params::Check::NO_DUPLICATES = 1;

    my $mod;
    my $tmpl = { module => { default => '', store => \$mod }, };

    my $args = check( $tmpl, \%hash ) or return;

    unless ($mod) {
        my @list = $self->modules;
        if (@list) {
            $mod = $list[0];
        }
        else {
            error( loc("This author has released no modules") );
            return;
        }
    }

    my $file = $mod->checksums(%hash);
    my $href = $mod->_parse_checksums_file( file => $file ) or return;

    my @rv;
    for my $name ( keys %$href ) {

        next if $mod->package_extension($name) eq META_EXT;

        my $dist = CPANPLUS::Module::Fake->new(
            module => do {
                my $m = $mod->package_name($name);
                $m =~ s/-/::/g;
                $m;
            },
            version => $mod->package_version($name),
            package => $name,
            path    => $mod->path, author => $mod->author, mtime =>
              $href->{$name}->{'mtime'}, );

        push @rv, $dist;
    }

    return @rv;
}


sub accessors { return keys %$tmpl }

1;

