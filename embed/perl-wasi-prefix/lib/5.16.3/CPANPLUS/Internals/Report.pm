package CPANPLUS::Internals::Report;

use strict;

use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;
use CPANPLUS::Internals::Constants::Report;

use Data::Dumper;

use Params::Check qw[check];
use Module::Load::Conditional qw[can_load];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';
use version;

$Params::Check::VERBOSE = 1;

require CPANPLUS::Internals;


{
    my $query_list = {
        'File::Fetch'       => '0.13_02',
        'Parse::CPAN::Meta' => '0.0',
        'File::Temp'        => '0.0',
    };

    my $send_list = { %$query_list, 'Test::Reporter' => '1.54', };

    sub _have_query_report_modules {
        my $self = shift;
        my $conf = $self->configure_object;
        my %hash = @_;

        my $tmpl = { verbose => { default => $conf->get_conf('verbose') }, };

        my $args = check( $tmpl, \%hash ) or return;

        return can_load( modules => $query_list, verbose => $args->{verbose} )
          ? 1
          : 0;
    }

    sub _have_send_report_modules {
        my $self = shift;
        my $conf = $self->configure_object;
        my %hash = @_;

        my $tmpl = { verbose => { default => $conf->get_conf('verbose') }, };

        my $args = check( $tmpl, \%hash ) or return;

        return can_load( modules => $send_list, verbose => $args->{verbose} )
          ? 1
          : 0;
    }
}


sub _query_report {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    my ( $mod, $verbose, $all );
    my $tmpl = {
        module => {
            required => 1,
            allow    => IS_MODOBJ,
            store    => \$mod
        },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        all_versions => { default => 0, store => \$all },
    };

    check( $tmpl, \%hash ) or return;

    return unless $self->_have_query_report_modules( verbose => 1 );

    my $url = TESTERS_URL->( $mod->package_name );
    my $ff = File::Fetch->new( uri => $url );

    msg( loc( "Fetching: '%1'", $url ), $verbose );

    my $res = do {
        my $tempdir = File::Temp::tempdir();
        my $where = $ff->fetch( to => $tempdir );

        unless ($where) {
            error(
                loc( "Fetching report for '%1' failed: %2", $url, $ff->error )
            );
            return;
        }

        my $fh = OPEN_FILE->($where);

        do { local $/; <$fh> };
    };

    my ($aref) = eval { Parse::CPAN::Meta::Load($res) };

    if ($@) {
        error( loc( "Error reading result: %1", $@ ) );
        return;
    }

    my $dist    = $mod->package_name . '-' . $mod->package_version;
    my $details = TESTERS_DETAILS_URL->( $mod->package_name );

    my @rv;
    for my $href (@$aref) {
        next
          unless $all
          or defined $href->{'distversion'} && $href->{'distversion'} eq $dist;

        $href->{'details'} = $details;

        $href->{'dist'} ||= $href->{'distversion'};
        $href->{'grade'} ||= $href->{'action'} || $href->{'status'};

        push @rv, $href;
    }

    return @rv if @rv;
    return;
}


sub _send_report {
    my $self = shift;
    my $conf = $self->configure_object;
    my %hash = @_;

    unless ( $self->_have_send_report_modules( verbose => 1 ) ) {
        error(
            loc(
                "You don't have '%1' (or modules required by '%2') "
                  . "installed, you cannot report test results.",
                'Test::Reporter',
                'Test::Reporter'
            )
        );
        return;
    }

    my (
        $buffer,  $failed, $mod,           $verbose, $force,
        $address, $save,   $tests_skipped, $status
    );
    my $tmpl = {
        module => { required => 1, store => \$mod, allow => IS_MODOBJ },
        buffer => { required => 1, store => \$buffer },
        failed => { required => 1, store => \$failed },
        status => { default => {}, store => \$status, strict_type => 1 },
        address => { default => CPAN_TESTERS_EMAIL, store => \$address },
        save    => { default => 0,                  store => \$save },
        verbose => {
            default => $conf->get_conf('verbose'),
            store   => \$verbose
        },
        force => {
            default => $conf->get_conf('force'),
            store   => \$force
        },
        tests_skipped => { default => 0, store => \$tests_skipped },
    };

    check( $tmpl, \%hash ) or return;

    my $name     = $mod->module;
    my $dist     = $mod->package_name . '-' . $mod->package_version;
    my $author   = $mod->author->author;
    my $distfile = $mod->author->cpanid . "/" . $mod->package;
    my $email    = $mod->author->email || CPAN_MAIL_ACCOUNT->($author);
    my $cp_conf  = $conf->get_conf('cpantest') || '';
    my $int_ver  = $CPANPLUS::Internals::VERSION;
    my $cb       = $mod->parent;

    my $stage = TEST_FAIL_STAGE->($buffer);

    my $grade;
  GRADE: {
        if ($failed) {

            {
                my $prq = $mod->status->prereqs || {};

              PREREQ: while ( my ( $prq_name, $prq_ver ) = each %$prq ) {

                    if ( $prq_name eq 'perl' ) {
                        my $req_ver = eval { version->new($prq_ver) };
                        next PREREQ unless $req_ver;
                        if ( version->new($]) < $req_ver ) {
                            msg(
                                loc(
"'%1' requires a higher version of perl than your current "
                                      . "version -- sending N/A grade.",
                                    $name
                                ),
                                $verbose
                            );

                            $grade = GRADE_NA;
                            last GRADE;
                        }
                        next PREREQ;
                    }

                    my $obj = $cb->module_tree($prq_name);
                    my $sub = CPANPLUS::Module->can(
                        'module_is_supplied_with_perl_core');

                    if ( !$obj and !defined $sub->($prq_name) ) {
                        msg(
                            loc(
"Prerequisite '%1' for '%2' could not be obtained"
                                  . " from CPAN -- sending N/A grade",
                                $prq_name,
                                $name
                            ),
                            $verbose
                        );

                        $grade = GRADE_NA;
                        last GRADE;
                    }

                    if ( !$obj ) {
                        my $vcore = $sub->($prq_name);
                        if ( $cb->_vcmp( $prq_ver, $vcore ) > 0 ) {
                            msg(
                                loc(
"Version of core module '%1' ('%2') is too low for "
                                      . "'%3' (needs '%4') -- sending N/A grade",
                                    $prq_name, $vcore, $name, $prq_ver
                                ),
                                $verbose
                            );

                            $grade = GRADE_NA;
                            last GRADE;
                        }
                    }

                    if (    $obj
                        and $cb->_vcmp( $prq_ver, $obj->installed_version ) >
                        0 )
                    {
                        msg(
                            loc(
"Installed version of '%1' ('%2') is too low for "
                                  . "'%3' (needs '%4') -- sending N/A grade",
                                $prq_name, $obj->installed_version,
                                $name,     $prq_ver
                            ),
                            $verbose
                        );

                        $grade = GRADE_NA;
                        last GRADE;
                    }
                }
            }

            unless ( RELEVANT_TEST_RESULT->($mod) ) {
                msg(
                    loc(
"'%1' is a platform specific module, and the test results on"
                          . " your platform are not relevant --sending N/A grade.",
                        $name
                    ),
                    $verbose
                );

                $grade = GRADE_NA;

            }
            elsif ( UNSUPPORTED_OS->($buffer) ) {
                msg(
                    loc(
"'%1' is a platform specific module, and the test results on"
                          . " your platform are not relevant --sending N/A grade.",
                        $name
                    ),
                    $verbose
                );

                $grade = GRADE_NA;

            }
            elsif ( PERL_VERSION_TOO_LOW->($buffer) ) {
                msg(
                    loc(
"'%1' requires a higher version of perl than your current "
                          . "version -- sending N/A grade.",
                        $name
                    ),
                    $verbose
                );

                $grade = GRADE_NA;

            }
            elsif ( NO_TESTS_DEFINED->($buffer) ) {
                $grade = GRADE_UNKNOWN;
            }
            elsif ( $stage !~ /\btest\b/ ) {

                $grade = GRADE_UNKNOWN

            }
            else {

                $grade = GRADE_FAIL;
            }

        }
        else {
            $grade = GRADE_PASS;
        }
    }

    my $message = REPORT_MESSAGE_HEADER->( $int_ver, $author );

    if ( $grade eq GRADE_FAIL or $grade eq GRADE_UNKNOWN ) {

        if ( my @missing = MISSING_EXTLIBS_LIST->($buffer) ) {
            msg(
                loc(
                        "Not sending test report - "
                      . "external libraries not pre-installed"
                )
            );
            return 1;
        }

        return 1
          if $cp_conf =~ /\bmaketest_only\b/i
          and ( $stage !~ /\btest\b/ );

        my $capture =
          ( $status
              && defined $status->{capture} ? $status->{capture} : $buffer );
        $message .= REPORT_MESSAGE_FAIL_HEADER->( $stage, $capture );

        if ( my @missing = MISSING_PREREQS_LIST->($buffer) ) {
            if (
                !$self->_verify_missing_prereqs(
                    module  => $mod,
                    missing => \@missing
                )
              )
            {
                msg(
                    loc(
                            "Not sending test report - "
                          . "bogus missing prerequisites report"
                    )
                );
                return 1;
            }
            $message .= REPORT_MISSING_PREREQS->( $author, $email, @missing );
        }

        if ( NO_TESTS_DEFINED->($buffer) ) {
            $message .= REPORT_MISSING_TESTS->();
        }

        $message .= REPORT_LOADED_PREREQS->($mod);

        $message .= REPORT_TOOLCHAIN_VERSIONS->($mod);

        $message .= REPORT_MESSAGE_FOOTER->();

    }
    elsif ($tests_skipped) {
        $message .= REPORT_TESTS_SKIPPED->();
    }
    elsif ( $grade eq GRADE_NA ) {

        my $capture =
          ( $status
              && defined $status->{capture} ? $status->{capture} : $buffer );

        $capture = join $/, $capture,
          map { '[' . $_->tag . '] [' . $_->when . '] ' . $_->message }
          ( CPANPLUS::Error->stack )[-1];

        $message .= REPORT_MESSAGE_FAIL_HEADER->( $stage, $capture );

        $message .= REPORT_LOADED_PREREQS->($mod);

        $message .= REPORT_TOOLCHAIN_VERSIONS->($mod);

        $message .= REPORT_MESSAGE_FOOTER->();

    }
    elsif ( $grade eq GRADE_PASS
        and ( $status and defined $status->{capture} ) )
    {
        $message .= REPORT_MESSAGE_PASS_HEADER->( $stage, $status->{capture} );

        $message .= REPORT_LOADED_PREREQS->($mod);

        $message .= REPORT_TOOLCHAIN_VERSIONS->($mod);

        $message .= REPORT_MESSAGE_FOOTER->();

    }

    msg( loc( "Sending test report for '%1'", $dist ), $verbose );

    my $reporter = do {
        my $args = $conf->get_conf('cpantest_reporter_args') || {};

        unless ( UNIVERSAL::isa( $args, 'HASH' ) ) {
            error(
                loc(
                    "'%1' must be a hashref, ignoring...",
                    'cpantest_reporter_args'
                )
            );
            $args = {};
        }

        Test::Reporter->new(
            grade        => $grade,
            distribution => $dist,
            distfile     => $distfile,
            via          => "CPANPLUS $int_ver",
            timeout      => $conf->get_conf('timeout') || 60,
            debug        => $conf->get_conf('debug'),
            %$args,
        );
    };

    $reporter->mx( [ $conf->get_conf('cpantest_mx') ] )
      if $conf->get_conf('cpantest_mx');

    $reporter->from( $conf->get_conf('email') )
      if $conf->get_conf('email') !~ /\@example\.\w+$/i;

    $message = $self->_callbacks->munge_test_report->( $mod, $message, $grade );

    $reporter->comments($message) if defined $message && length $message;

    unless ( $self->_callbacks->send_test_report->( $mod, $grade ) ) {
        msg( loc("Ok, not sending test report") );
        return 1;
    }

    if ( $self->_callbacks->edit_test_report->( $mod, $grade ) ) {
        local $ENV{VISUAL} = $conf->get_program('editor')
          if $conf->get_program('editor');

        $reporter->edit_comments;
    }

    $reporter->address($address);

    if ($save) {
        if ( my $file = $reporter->write() ) {
            msg(
                loc(
                    "Successfully wrote report for '%1' to '%2'", $dist,
                    $file
                ),
                $verbose
            );
            return $file;

        }
        else {
            error( loc( "Failed to write report for '%1'", $dist ) );
            return;
        }

    }
    else {
        my $status;
        eval { $status = $reporter->send(); };
        if ($@) {
            error(
                loc(
                    "Could not send '%1' report for '%2': %3",
                    $grade, $dist, $@
                )
            );
            return;
        }
        if ($status) {
            msg( loc( "Successfully sent '%1' report for '%2'", $grade, $dist ),
                $verbose );
            return 1;
        }
        error(
            loc(
                "Could not send '%1' report for '%2': %3",
                $grade, $dist, $reporter->errstr
            )
        );
        return;
    }
}

sub _verify_missing_prereqs {
    my $self = shift;
    my %hash = @_;

    my ( $mod, $missing );
    my $tmpl = {
        module  => { required => 1, store => \$mod },
        missing => { required => 1, store => \$missing },
    };

    check( $tmpl, \%hash ) or return;

    my %missing = map { $_ => 1 } @$missing;
    my $conf    = $self->configure_object;
    my $extract = $mod->status->extract;

    my @search;
    push @search, ( $extract ? MAKEFILE_PL->($extract) : MAKEFILE_PL->() );
    push @search, ( $extract ? BUILD_PL->($extract)    : BUILD_PL->() );

    for my $file (@search) {
        if ( -e $file and -r $file ) {
            my $slurp = $self->_get_file_contents( file => $file );
            my ($prereq) =
              ( $slurp =~ /'?(?:PREREQ_PM|requires)'?\s*=>\s*{(.*?)}/s );
            my @prereq =
              ( $prereq =~ /'?([\w\:]+)'?\s*=>\s*'?\d[\d\.\-\_]*'?/sg );
            delete $missing{$_} for (@prereq);
        }
    }

    return 1 if ( keys %missing );
    return;
}

1;

