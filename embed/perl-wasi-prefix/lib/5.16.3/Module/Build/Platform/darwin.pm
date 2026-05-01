package Module::Build::Platform::darwin;

use strict;
use vars qw($VERSION);
$VERSION = '0.39_01';
$VERSION = eval $VERSION;
use Module::Build::Platform::Unix;

use vars qw(@ISA);
@ISA = qw(Module::Build::Platform::Unix);

1;
__END__


