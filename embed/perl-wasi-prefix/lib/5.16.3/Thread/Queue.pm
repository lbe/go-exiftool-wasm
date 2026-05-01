package Thread::Queue;

use strict;
use warnings;

our $VERSION = '2.12';
$VERSION = eval $VERSION;

use threads::shared 1.21;
use Scalar::Util 1.10 qw(looks_like_number blessed reftype refaddr);

our @CARP_NOT = ("threads::shared");

my ( $validate_count, $validate_index );

sub new {
    my $class = shift;
    my @queue : shared = map { shared_clone($_) } @_;
    return bless( \@queue, $class );
}

sub enqueue {
    my $queue = shift;
    lock(@$queue);
    push( @$queue, map { shared_clone($_) } @_ )
      and cond_signal(@$queue);
}

sub pending {
    my $queue = shift;
    lock(@$queue);
    return scalar(@$queue);
}

sub dequeue {
    my $queue = shift;
    lock(@$queue);

    my $count = @_ ? $validate_count->(shift) : 1;

    cond_wait(@$queue) until ( @$queue >= $count );
    cond_signal(@$queue) if ( @$queue > $count );

    return shift(@$queue) if ( $count == 1 );

    my @items;
    push( @items, shift(@$queue) ) for ( 1 .. $count );
    return @items;
}

sub dequeue_nb {
    my $queue = shift;
    lock(@$queue);

    my $count = @_ ? $validate_count->(shift) : 1;

    return shift(@$queue) if ( $count == 1 );

    my @items;
    for ( 1 .. $count ) {
        last if ( !@$queue );
        push( @items, shift(@$queue) );
    }
    return @items;
}

sub peek {
    my $queue = shift;
    lock(@$queue);
    my $index = @_ ? $validate_index->(shift) : 0;
    return $$queue[$index];
}

sub insert {
    my $queue = shift;
    lock(@$queue);

    my $index = $validate_index->(shift);

    return if ( !@_ );

    if ( $index < 0 ) {
        $index += @$queue;
        if ( $index < 0 ) {
            $index = 0;
        }
    }

    my @tmp;
    while ( @$queue > $index ) {
        unshift( @tmp, pop(@$queue) );
    }

    push( @$queue, map { shared_clone($_) } @_ );

    push( @$queue, @tmp );

    cond_signal(@$queue);
}

sub extract {
    my $queue = shift;
    lock(@$queue);

    my $index = @_ ? $validate_index->(shift) : 0;
    my $count = @_ ? $validate_count->(shift) : 1;

    if ( $index < 0 ) {
        $index += @$queue;
        if ( $index < 0 ) {
            $count += $index;
            return if ( $count <= 0 );
            return $queue->dequeue_nb($count);
        }
    }

    my @tmp;
    while ( @$queue > ( $index + $count ) ) {
        unshift( @tmp, pop(@$queue) );
    }

    my @items;
    unshift( @items, pop(@$queue) ) while ( @$queue > $index );

    push( @$queue, @tmp );

    return $items[0] if ( $count == 1 );

    return @items;
}

$validate_index = sub {
    my $index = shift;

    if (   !defined($index)
        || !looks_like_number($index)
        || ( int($index) != $index ) )
    {
        require Carp;
        my ($method) = ( caller(1) )[3];
        $method =~ s/Thread::Queue:://;
        $index = 'undef' if ( !defined($index) );
        Carp::croak("Invalid 'index' argument ($index) to '$method' method");
    }

    return $index;
};

$validate_count = sub {
    my $count = shift;

    if (   !defined($count)
        || !looks_like_number($count)
        || ( int($count) != $count )
        || ( $count < 1 ) )
    {
        require Carp;
        my ($method) = ( caller(1) )[3];
        $method =~ s/Thread::Queue:://;
        $count = 'undef' if ( !defined($count) );
        Carp::croak("Invalid 'count' argument ($count) to '$method' method");
    }

    return $count;
};

1;

