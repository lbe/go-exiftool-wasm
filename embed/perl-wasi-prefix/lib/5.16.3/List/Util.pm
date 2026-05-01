
package List::Util;

use strict;
require Exporter;

our @ISA        = qw(Exporter);
our @EXPORT_OK  = qw(first min max minstr maxstr reduce sum shuffle);
our $VERSION    = "1.25";
our $XS_VERSION = $VERSION;
$VERSION = eval $VERSION;

require XSLoader;
XSLoader::load( 'List::Util', $XS_VERSION );

1;

__END__

