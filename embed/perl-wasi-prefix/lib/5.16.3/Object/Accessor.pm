package Object::Accessor;

use strict;
use Carp qw[carp croak];
use vars qw[$FATAL $DEBUG $AUTOLOAD $VERSION];
use Params::Check qw[allow];
use Data::Dumper;

require overload;

$VERSION = '0.42';
$FATAL   = 0;
$DEBUG   = 0;

use constant VALUE => 0;
use constant ALLOW => 1;
use constant ALIAS => 2;


sub new {
    my $class = shift;
    my $obj = bless {}, $class;

    $obj->mk_accessors(@_) if @_;

    return $obj;
}


sub mk_accessors {
    my $self = $_[0];
    my $is_hash = UNIVERSAL::isa( $_[1], 'HASH' );

    for my $acc ( $is_hash ? keys %{ $_[1] } : @_[ 1 .. $#_ ] ) {

        if ( exists $self->{$acc} ) {
            __PACKAGE__->___debug("Accessor '$acc' already exists");
            next;
        }

        __PACKAGE__->___debug("Creating accessor '$acc'");

        $self->{$acc}->[VALUE] = undef;

        $self->{$acc}->[ALLOW] = $_[1]->{$acc} if $is_hash;
    }

    return 1;
}


sub ls_accessors {
    return sort grep { $_ ne "$_[0]" } keys %{ $_[0] };
}


sub ls_allow {
    my $self = shift;
    my $key = shift or return;
    return exists $self->{$key}->[ALLOW]
      ? $self->{$key}->[ALLOW]
      : sub { 1 };
}


sub mk_aliases {
    my $self    = shift;
    my %aliases = @_;

    while ( my ( $alias, $method ) = each %aliases ) {

        if ( exists $self->{$alias} ) {
            __PACKAGE__->___debug("Accessor '$alias' already exists");
            next;
        }

        $self->___alias( $alias => $method );
    }

    return 1;
}


sub mk_clone {
    my $self  = $_[0];
    my $class = ref $self;

    my $clone = $class->new;

    my %hash;
    my @list;
    for my $acc ( $self->ls_accessors ) {
        my $allow = $self->{$acc}->[ALLOW];
        $allow ? $hash{$acc} = $allow : push @list, $acc;

        if ( my $org = $self->{$acc}->[ALIAS] ) {
            $clone->___alias( $acc => $org );
        }
    }

    $clone->mk_accessors( \%hash ) if %hash;
    $clone->mk_accessors(@list) if @list;

    $clone->___callback( $self->___callback );

    return $clone;
}


sub mk_flush {
    my $self = $_[0];

    $self->{$_}->[VALUE] = undef for $self->ls_accessors;

    return 1;
}


sub mk_verify {
    my $self = $_[0];

    my $fail;
    for my $name ( $self->ls_accessors ) {
        unless ( allow( $self->$name, $self->ls_allow($name) ) ) {
            my $val = defined $self->$name ? $self->$name : '<undef>';

            __PACKAGE__->___error("'$name' ($val) is invalid");
            $fail++;
        }
    }

    return if $fail;
    return 1;
}


sub register_callback {
    my $self = shift;
    my $sub = shift or return;

    $self->___callback($sub);

    return 1;
}


sub can {
    my ( $self, $method ) = @_;

    if ( $self->UNIVERSAL::can($method) ) {
        __PACKAGE__->___debug("Can '$method' -- provided by package");
        return $self->UNIVERSAL::can($method);
    }

    if ( UNIVERSAL::isa( $self, 'HASH' ) and exists $self->{$method} ) {
        __PACKAGE__->___debug("Can '$method' -- provided by object");
        return sub { $self->$method(@_); }
    }

    __PACKAGE__->___debug("Cannot '$method'");
    return;
}

sub DESTROY { 1 }

sub AUTOLOAD {
    my $self = shift;
    my ($method) = ( $AUTOLOAD =~ /([^:']+$)/ );

    my $val = $self->___autoload( $method, @_ ) or return;

    return $val->[0];
}

sub ___autoload {
    my $self   = shift;
    my $method = shift;
    my $assign = scalar @_;

    if ( UNIVERSAL::isa( $self, 'HASH' ) ) {
        if ( not exists $self->{$method} ) {
            __PACKAGE__->___error( "No such accessor '$method'", 1 );
            return;
        }

    }
    else {
        local $FATAL = 1;
        __PACKAGE__->___error(
            "You called '$AUTOLOAD' on '$self' which was interpreted by "
              . __PACKAGE__
              . " as an object call. Did you mean to include "
              . "'$method' from somewhere else?",
            1
        );
    }

    if ( my $original = $self->{$method}->[ALIAS] ) {
        return $self->___autoload( $original, @_ );
    }

    my $val = $assign ? shift(@_) : $self->___get($method);

    if ($assign) {

        if ( $_[0] ) {
            if ( ref $_[0] and UNIVERSAL::isa( $_[0], 'SCALAR' ) ) {

                my $cur = $self->{$method}->[VALUE];

                tie ${ $_[0] }, __PACKAGE__ . '::TIE',
                  sub { $self->$method($cur) };

                ${ $_[0] } = $val;

            }
            else {
                __PACKAGE__->___error(
                    "Can not bind '$method' to anything but a SCALAR", 1 );
            }
        }

        if ( defined $self->{$method}->[ALLOW] ) {

            local $Params::Check::VERBOSE = 0;
            local $Params::Check::VERBOSE = 0;

            allow( $val, $self->{$method}->[ALLOW] )
              or (
                __PACKAGE__->___error(
                    "'$val' is an invalid value for '$method'", 1
                ),
                return
              );
        }
    }

    if ( my $sub = $self->___callback ) {
        $val = eval { $sub->( $self, $method, ( $assign ? [$val] : [] ) ) };

        $self->___error( $@, 1 ), return if $@;
    }

    if ($assign) {
        $self->___set( $method, $val ) or return;
    }

    return [$val];
}


sub ___get {
    my $self = shift;
    my $method = shift or return;
    return $self->{$method}->[VALUE];
}


sub ___set {
    my $self = shift;
    my $method = shift or return;

    @_ or return;
    my $val = shift;

    $self->{$method}->[VALUE] = $val;

    return 1;
}


sub ___alias {
    my $self   = shift;
    my $alias  = shift or return;
    my $method = shift or return;

    $self->{$alias}->[ALIAS] = $method;

    return 1;
}

sub ___debug {
    return unless $DEBUG;

    my $self = shift;
    my $msg  = shift;
    my $lvl  = shift || 0;

    local $Carp::CarpLevel += 1;

    carp($msg);
}

sub ___error {
    my $self = shift;
    my $msg  = shift;
    my $lvl  = shift || 0;
    local $Carp::CarpLevel += ( $lvl + 1 );
    $FATAL ? croak($msg) : carp($msg);
}

sub ___callback {
    my $self = shift;
    my $sub  = shift;

    my $mem =
        overload::Overloaded($self)
      ? overload::StrVal($self)
      : "$self";

    $self->{$mem} = $sub if $sub;

    return $self->{$mem};
}


{

    package Object::Accessor::Lvalue;
    use base 'Object::Accessor';
    use strict;
    use vars qw[$AUTOLOAD];

    *VALUE = *Object::Accessor::VALUE;
    *ALLOW = *Object::Accessor::ALLOW;

    sub AUTOLOAD : lvalue {
        my $self = shift;
        my ($method) = ( $AUTOLOAD =~ /([^:']+$)/ );

        $self->___autoload( $method, @_ ) or return;

        $self->{$method}->[ VALUE() ];
    }

    sub mk_accessors {
        my $self = shift;
        my $is_hash = UNIVERSAL::isa( $_[0], 'HASH' );

        $self->___error( "Allow handlers are not supported for '"
              . __PACKAGE__
              . "' objects" )
          if $is_hash;

        return $self->SUPER::mk_accessors(@_);
    }

    sub register_callback {
        my $self = shift;
        $self->___error(
            "Callbacks are not supported for '" . __PACKAGE__ . "' objects" );
        return;
    }
}

{

    package Object::Accessor::TIE;
    use Tie::Scalar;
    use Data::Dumper;
    use base 'Tie::StdScalar';

    my %local = ();

    sub TIESCALAR {
        my $class = shift;
        my $sub   = shift;
        my $ref   = undef;
        my $obj   = bless \$ref, $class;

        $local{$obj} = $sub;
        return $obj;
    }

    sub DESTROY {
        my $tied = shift;
        my $sub  = delete $local{$tied};

        return $sub->();
    }
}


1;
