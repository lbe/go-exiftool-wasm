package CGI::Pretty;

use strict;
use CGI ();

$CGI::Pretty::VERSION       = '3.46';
$CGI::DefaultClass          = __PACKAGE__;
$CGI::Pretty::AutoloadClass = 'CGI';
@CGI::Pretty::ISA           = qw( CGI );

initialize_globals();

sub _prettyPrint {
    my $input = shift;
    return if !$$input;
    return if !$CGI::Pretty::LINEBREAK || !$CGI::Pretty::INDENT;

    foreach my $i (@CGI::Pretty::AS_IS) {
        if ( $$input =~ m{</$i>}si ) {
            my ( $a, $b, $c ) = $$input =~ m{(.*)(<$i[\s/>].*?</$i>)(.*)}si;
            next if !$b;
            $a ||= "";
            $c ||= "";

            _prettyPrint( \$a ) if $a;
            _prettyPrint( \$c ) if $c;

            $b ||= "";
            $$input = "$a$b$c";
            return;
        }
    }
    $$input =~
      s/$CGI::Pretty::LINEBREAK/$CGI::Pretty::LINEBREAK$CGI::Pretty::INDENT/g;
}

sub comment {
    my ( $self, @p ) = CGI::self_or_CGI(@_);

    my $s = "@p";
    $s =~
      s/$CGI::Pretty::LINEBREAK/$CGI::Pretty::LINEBREAK$CGI::Pretty::INDENT/g
      if $CGI::Pretty::LINEBREAK;

    return $self->SUPER::comment(
        "$CGI::Pretty::LINEBREAK$CGI::Pretty::INDENT$s$CGI::Pretty::LINEBREAK")
      . $CGI::Pretty::LINEBREAK;
}

sub _make_tag_func {
    my ( $self, $tagname ) = @_;

    my $func = qq"
	sub $tagname {";

    $func .= q'
            shift if $_[0] && 
                    (ref($_[0]) &&
                     (substr(ref($_[0]),0,3) eq "CGI" ||
                    UNIVERSAL::isa($_[0],"CGI")));
	    my($attr) = "";
	    if (ref($_[0]) && ref($_[0]) eq "HASH") {
		my(@attr) = make_attributes(shift()||undef,1);
		$attr = " @attr" if @attr;
	    }';

    if ( $tagname =~ /start_(\w+)/i ) {
        $func .= qq! 
            return "<\L$1\E\$attr>\$CGI::Pretty::LINEBREAK";} !;
    }
    elsif ( $tagname =~ /end_(\w+)/i ) {
        $func .= qq! 
            return "<\L/$1\E>\$CGI::Pretty::LINEBREAK"; } !;
    }
    else {
        $func .= qq#
	    return ( \$CGI::XHTML ? "<\L$tagname\E\$attr />" : "<\L$tagname\E\$attr>" ) .
                   \$CGI::Pretty::LINEBREAK unless \@_;
	    my(\$tag,\$untag) = ("<\L$tagname\E\$attr>","</\L$tagname>\E");

            my \%ASIS = map { lc("\$_") => 1 } \@CGI::Pretty::AS_IS;
            my \@args;
            if ( \$CGI::Pretty::LINEBREAK || \$CGI::Pretty::INDENT ) {
   	      if(ref(\$_[0]) eq 'ARRAY') {
                 \@args = \@{\$_[0]}
              } else {
                  foreach (\@_) {
		      \$args[0] .= \$_;
                      \$args[0] .= \$CGI::Pretty::LINEBREAK if \$args[0] !~ /\$CGI::Pretty::LINEBREAK\$/ && 0;
                      chomp \$args[0] if exists \$ASIS{ "\L$tagname\E" };
                      
  	              \$args[0] .= \$" if \$args[0] !~ /\$CGI::Pretty::LINEBREAK\$/ && 1;
		  }
                  chop \$args[0] unless \$" eq "";
	      }
            }
            else {
              \@args = ref(\$_[0]) eq 'ARRAY' ? \@{\$_[0]} : "\@_";
            }

            my \@result;
            if ( exists \$ASIS{ "\L$tagname\E" } ) {
                \@result = map { "\$tag\$_\$untag" } \@args;
            }
	    else {
		\@result = map { 
		    chomp; 
		    my \$tmp = \$_;
		    CGI::Pretty::_prettyPrint( \\\$tmp );
                    \$tag . \$CGI::Pretty::LINEBREAK .
                    \$CGI::Pretty::INDENT . \$tmp . \$CGI::Pretty::LINEBREAK . 
                    \$untag . \$CGI::Pretty::LINEBREAK
                } \@args;
	    }
            if (\$CGI::Pretty::LINEBREAK || \$CGI::Pretty::INDENT) {
                return join ("", \@result);
            } else {
                return "\@result";
            }
	}#;
    }

    return $func;
}

sub start_html {
    return CGI::start_html(@_) . $CGI::Pretty::LINEBREAK;
}

sub end_html {
    return CGI::end_html(@_) . $CGI::Pretty::LINEBREAK;
}

sub new {
    my $class = shift;
    my $this  = $class->SUPER::new(@_);

    if ($CGI::MOD_PERL) {
        if ( $CGI::MOD_PERL == 1 ) {
            my $r = Apache->request;
            $r->register_cleanup( \&CGI::Pretty::_reset_globals );
        }
        else {
            my $r = Apache2::RequestUtil->request;
            $r->pool->cleanup_register( \&CGI::Pretty::_reset_globals );
        }
    }
    $class->_reset_globals if $CGI::PERLEX;

    return bless $this, $class;
}

sub initialize_globals {
    $CGI::Pretty::INDENT = "\t";

    $CGI::Pretty::LINEBREAK = $/;

    @CGI::Pretty::AS_IS = qw( a pre code script textarea td );

    1;
}
sub _reset_globals { initialize_globals(); }

sub import {
    my $self = shift;
    no strict 'refs';
    ${"$self\::AutoloadClass"} = 'CGI';

    undef %CGI::EXPORT;
    undef %CGI::EXPORT;

    $self->_setup_symbols(@_);
    my ( $callpack, $callfile, $callline ) = caller;

    my @packages = ( $self, @{"$self\:\:ISA"} );
    foreach my $sym ( keys %CGI::EXPORT ) {
        my $pck;
        my $def = ${"$self\:\:AutoloadClass"} || $CGI::DefaultClass;
        foreach $pck (@packages) {
            if ( defined( &{"$pck\:\:$sym"} ) ) {
                $def = $pck;
                last;
            }
        }
        *{"${callpack}::$sym"} = \&{"$def\:\:$sym"};
    }
}

1;

