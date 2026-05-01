package MIME::QuotedPrint;

use strict;
use vars qw(@ISA @EXPORT $VERSION);

require Exporter;
@ISA    = qw(Exporter);
@EXPORT = qw(encode_qp decode_qp);

$VERSION = "3.13";

use MIME::Base64;

*encode = \&encode_qp;
*decode = \&decode_qp;

1;

__END__

