package subs;

our $VERSION = '1.01';


require 5.000;

sub import {
    my $callpack = caller;
    my $pack     = shift;
    my @imports  = @_;
    foreach $sym (@imports) {
        *{"${callpack}::$sym"} = \&{"${callpack}::$sym"};
    }
}

1;
