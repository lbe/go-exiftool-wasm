package File::Spec::Epoc;

use strict;
use vars qw($VERSION @ISA);

$VERSION = '3.39_02';
$VERSION =~ tr/_//;

require File::Spec::Unix;
@ISA = qw(File::Spec::Unix);


sub case_tolerant {
    return 1;
}


sub canonpath {
    my ( $self, $path ) = @_;
    return unless defined $path;

    $path =~ s|/+|/|g;
    $path =~ s|(/\.)+/|/|g;
    $path =~ s|^(\./)+||s unless $path eq "./";
    $path =~ s|^/(\.\./)+|/|s;
    $path =~ s|/\Z(?!\n)|| unless $path eq "/";
    return $path;
}


1;
