
package warnings;

our $VERSION = '1.13';

unless ( __FILE__ =~ /(^|[\/\\])\Q${\__PACKAGE__}\E\.pmc?$/ ) {
    my ( undef, $f, $l ) = caller;
    die("Incorrect use of pragma '${\__PACKAGE__}' at $f line $l.\n");
}


our %Offsets = (

    'all'           => 0,
    'closure'       => 2,
    'deprecated'    => 4,
    'exiting'       => 6,
    'glob'          => 8,
    'io'            => 10,
    'closed'        => 12,
    'exec'          => 14,
    'layer'         => 16,
    'newline'       => 18,
    'pipe'          => 20,
    'unopened'      => 22,
    'misc'          => 24,
    'numeric'       => 26,
    'once'          => 28,
    'overflow'      => 30,
    'pack'          => 32,
    'portable'      => 34,
    'recursion'     => 36,
    'redefine'      => 38,
    'regexp'        => 40,
    'severe'        => 42,
    'debugging'     => 44,
    'inplace'       => 46,
    'internal'      => 48,
    'malloc'        => 50,
    'signal'        => 52,
    'substr'        => 54,
    'syntax'        => 56,
    'ambiguous'     => 58,
    'bareword'      => 60,
    'digit'         => 62,
    'parenthesis'   => 64,
    'precedence'    => 66,
    'printf'        => 68,
    'prototype'     => 70,
    'qw'            => 72,
    'reserved'      => 74,
    'semicolon'     => 76,
    'taint'         => 78,
    'threads'       => 80,
    'uninitialized' => 82,
    'unpack'        => 84,
    'untie'         => 86,
    'utf8'          => 88,
    'void'          => 90,

    'imprecision'  => 92,
    'illegalproto' => 94,

    'non_unicode' => 96,
    'nonchar'     => 98,
    'surrogate'   => 100,
);

our %Bits = (
    'all' =>
      "\x55\x55\x55\x55\x55\x55\x55\x55\x55\x55\x55\x55\x15", 'ambiguous' =>
      "\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00", 'bareword' =>
      "\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00", 'closed' =>
      "\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'closure' =>
      "\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'debugging' =>
      "\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00", 'deprecated' =>
      "\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'digit' =>
      "\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00", 'exec' =>
      "\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'exiting' =>
      "\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'glob' =>
      "\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'illegalproto' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00", 'imprecision' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00", 'inplace' =>
      "\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00", 'internal' =>
      "\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00", 'io' =>
      "\x00\x54\x55\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'layer' =>
      "\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'malloc' =>
      "\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00", 'misc' =>
      "\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'newline' =>
      "\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'non_unicode' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01", 'nonchar' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04", 'numeric' =>
      "\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'once' =>
      "\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'overflow' =>
      "\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'pack' =>
      "\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00", 'parenthesis' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00", 'pipe' =>
      "\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'portable' =>
      "\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00", 'precedence' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00", 'printf' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00", 'prototype' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00", 'qw' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00", 'recursion' =>
      "\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00", 'redefine' =>
      "\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00", 'regexp' =>
      "\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00", 'reserved' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00", 'semicolon' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00", 'severe' =>
      "\x00\x00\x00\x00\x00\x54\x05\x00\x00\x00\x00\x00\x00", 'signal' =>
      "\x00\x00\x00\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00", 'substr' =>
      "\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00", 'surrogate' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10", 'syntax' =>
      "\x00\x00\x00\x00\x00\x00\x00\x55\x55\x15\x00\x40\x00", 'taint' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00", 'threads' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00", 'uninitialized' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00", 'unopened' =>
      "\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'unpack' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\x00", 'untie' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00", 'utf8' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x15", 'void' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x00", );

our %DeadBits = (
    'all' =>
      "\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\xaa\x2a", 'ambiguous' =>
      "\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x00\x00", 'bareword' =>
      "\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00\x00\x00\x00", 'closed' =>
      "\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'closure' =>
      "\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'debugging' =>
      "\x00\x00\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00", 'deprecated' =>
      "\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'digit' =>
      "\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00", 'exec' =>
      "\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'exiting' =>
      "\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'glob' =>
      "\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'illegalproto' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00", 'imprecision' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x20\x00", 'inplace' =>
      "\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00", 'internal' =>
      "\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00", 'io' =>
      "\x00\xa8\xaa\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'layer' =>
      "\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'malloc' =>
      "\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00", 'misc' =>
      "\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'newline' =>
      "\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'non_unicode' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02", 'nonchar' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08", 'numeric' =>
      "\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'once' =>
      "\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'overflow' =>
      "\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'pack' =>
      "\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00", 'parenthesis' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00", 'pipe' =>
      "\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'portable' =>
      "\x00\x00\x00\x00\x08\x00\x00\x00\x00\x00\x00\x00\x00", 'precedence' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00\x00", 'printf' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00\x00\x00", 'prototype' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00", 'qw' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00", 'recursion' =>
      "\x00\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00", 'redefine' =>
      "\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00", 'regexp' =>
      "\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00", 'reserved' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00\x00", 'semicolon' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00\x00", 'severe' =>
      "\x00\x00\x00\x00\x00\xa8\x0a\x00\x00\x00\x00\x00\x00", 'signal' =>
      "\x00\x00\x00\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00", 'substr' =>
      "\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00\x00\x00\x00", 'surrogate' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x20", 'syntax' =>
      "\x00\x00\x00\x00\x00\x00\x00\xaa\xaa\x2a\x00\x80\x00", 'taint' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00\x00", 'threads' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00", 'uninitialized' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00\x00", 'unopened' =>
      "\x00\x00\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00", 'unpack' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x20\x00\x00", 'untie' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x00\x00", 'utf8' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x2a", 'void' =>
      "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x08\x00", );

$NONE     = "\0\0\0\0\0\0\0\0\0\0\0\0\0";
$LAST_BIT = 102;
$BYTES    = 13;

$All = "";
vec( $All, $Offsets{'all'}, 2 ) = 3;

sub Croaker {
    require Carp;
    local $Carp::CarpInternal{'warnings'};
    delete $Carp::CarpInternal{'warnings'};
    Carp::croak(@_);
}

sub _bits {
    my $mask = shift;
    my $catmask;
    my $fatal    = 0;
    my $no_fatal = 0;

    foreach my $word (@_) {
        if ( $word eq 'FATAL' ) {
            $fatal    = 1;
            $no_fatal = 0;
        }
        elsif ( $word eq 'NONFATAL' ) {
            $fatal    = 0;
            $no_fatal = 1;
        }
        elsif ( $catmask = $Bits{$word} ) {
            $mask |= $catmask;
            $mask |= $DeadBits{$word} if $fatal;
            $mask &= ~( $DeadBits{$word} | $All ) if $no_fatal;
        }
        else { Croaker("Unknown warnings category '$word'") }
    }

    return $mask;
}

sub bits {
    push @_, 'all' unless @_;
    return _bits( undef, @_ );
}

sub import {
    shift;

    my $mask = ${^WARNING_BITS} // ( $^W ? $Bits{all} : $NONE );

    if ( vec( $mask, $Offsets{'all'}, 1 ) ) {
        $mask |= $Bits{'all'};
        $mask |= $DeadBits{'all'} if vec( $mask, $Offsets{'all'} + 1, 1 );
    }

    ${^WARNING_BITS} = @_ ? _bits( $mask, @_ ) : $mask | $Bits{all};
}

sub unimport {
    shift;

    my $catmask;
    my $mask = ${^WARNING_BITS} // ( $^W ? $Bits{all} : $NONE );

    if ( vec( $mask, $Offsets{'all'}, 1 ) ) {
        $mask |= $Bits{'all'};
        $mask |= $DeadBits{'all'} if vec( $mask, $Offsets{'all'} + 1, 1 );
    }

    push @_, 'all' unless @_;

    foreach my $word (@_) {
        if ( $word eq 'FATAL' ) {
            next;
        }
        elsif ( $catmask = $Bits{$word} ) {
            $mask &= ~( $catmask | $DeadBits{$word} | $All );
        }
        else { Croaker("Unknown warnings category '$word'") }
    }

    ${^WARNING_BITS} = $mask;
}

my %builtin_type;
@builtin_type{qw(SCALAR ARRAY HASH CODE REF GLOB LVALUE Regexp)} = ();

sub MESSAGE () { 4 }
sub FATAL ()   { 2 }
sub NORMAL ()  { 1 }

sub __chk {
    my $category;
    my $offset;
    my $isobj       = 0;
    my $wanted      = shift;
    my $has_message = $wanted & MESSAGE;

    unless ( @_ == 1 || @_ == ( $has_message ? 2 : 0 ) ) {
        my $sub = ( caller 1 )[3];
        my $syntax = $has_message ? "[category,] 'message'" : '[category]';
        Croaker("Usage: $sub($syntax)");
    }

    my $message = pop if $has_message;

    if (@_) {
        $category = shift;
        if ( my $type = ref $category ) {
            Croaker("not an object")
              if exists $builtin_type{$type};
            $category = $type;
            $isobj    = 1;
        }
        $offset = $Offsets{$category};
        Croaker("Unknown warnings category '$category'")
          unless defined $offset;
    }
    else {
        $category = ( caller(1) )[0];
        $offset   = $Offsets{$category};
        Croaker("package '$category' not registered for warnings")
          unless defined $offset;
    }

    my $i;

    if ($isobj) {
        my $pkg;
        $i = 2;
        while (
            do {
                { package DB; $pkg = ( caller( $i++ ) )[0] }
            }
          )
        {
            last unless @DB::args && $DB::args[0] =~ /^$category=/;
        }
        $i -= 2;
    }
    else {
        $i = _error_loc();
    }

    my $callers_bitmask = ( caller($i) )[9] || 0;

    my @results;
    foreach my $type ( FATAL, NORMAL ) {
        next unless $wanted & $type;

        push @results,
          (      vec( $callers_bitmask, $offset + $type - 1, 1 )
              || vec( $callers_bitmask, $Offsets{'all'} + $type - 1, 1 ) );
    }

    return $results[0] unless $has_message;

    return
      if $wanted == ( NORMAL | FATAL | MESSAGE )
      && !( $results[0] || $results[1] );

    require Carp;
    Carp::croak($message) if $results[0];
    Carp::carp($message);
}

sub _mkMask {
    my ($bit) = @_;
    my $mask = "";

    vec( $mask, $bit, 1 ) = 1;
    return $mask;
}

sub register_categories {
    my @names = @_;

    for my $name (@names) {
        if ( !defined $Bits{$name} ) {
            $Bits{$name} = _mkMask($LAST_BIT);
            vec( $Bits{'all'}, $LAST_BIT, 1 ) = 1;
            $Offsets{$name} = $LAST_BIT++;
            foreach my $k ( keys %Bits ) {
                vec( $Bits{$k}, $LAST_BIT, 1 ) = 0;
            }
            $DeadBits{$name} = _mkMask($LAST_BIT);
            vec( $DeadBits{'all'}, $LAST_BIT++, 1 ) = 1;
        }
    }
}

sub _error_loc {
    require Carp;
    goto &Carp::short_error_loc;
}

sub enabled {
    return __chk( NORMAL, @_ );
}

sub fatal_enabled {
    return __chk( FATAL, @_ );
}

sub warn {
    return __chk( FATAL | MESSAGE, @_ );
}

sub warnif {
    return __chk( NORMAL | FATAL | MESSAGE, @_ );
}

delete $warnings::{$_} foreach qw(NORMAL FATAL MESSAGE);

1;

