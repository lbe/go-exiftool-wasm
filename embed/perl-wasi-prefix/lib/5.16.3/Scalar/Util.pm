
package Scalar::Util;

use strict;
require Exporter;
require List::Util;

our @ISA = qw(Exporter);
our @EXPORT_OK =
  qw(blessed dualvar reftype weaken isweak tainted readonly openhandle refaddr isvstring looks_like_number set_prototype);
our $VERSION = "1.25";
$VERSION = eval $VERSION;

our @EXPORT_FAIL;

unless ( defined &weaken ) {
    push @EXPORT_FAIL, qw(weaken);
}
unless ( defined &isweak ) {
    push @EXPORT_FAIL, qw(isweak isvstring);
}
unless ( defined &isvstring ) {
    push @EXPORT_FAIL, qw(isvstring);
}

sub export_fail {
    if ( grep { /^(?:weaken|isweak)$/ } @_ ) {
        require Carp;
        Carp::croak(
            "Weak references are not implemented in the version of perl");
    }

    if ( grep { /^isvstring$/ } @_ ) {
        require Carp;
        Carp::croak("Vstrings are not implemented in the version of perl");
    }

    @_;
}

1;

__END__

