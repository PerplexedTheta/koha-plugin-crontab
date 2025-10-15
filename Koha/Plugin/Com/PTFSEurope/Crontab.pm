use utf8;

package Koha::Plugin::Com::PTFSEurope::Crontab;

use Modern::Perl;
use base qw(Koha::Plugins::Base);

use POSIX qw(strftime);
use Module::Metadata;
use JSON;

use C4::Context;

BEGIN {
    my $path = Module::Metadata->find_module_by_name(__PACKAGE__);
    $path =~ s{[.]pm$}{/lib}xms;
    unshift @INC, $path;
}


our $VERSION  = "{VERSION}";
our $metadata = {
    name            => 'Crontab',
    author          => 'Martin Renvoize',
    description     => 'Script scheduling',
    date_authored   => '2023-04-25',
    date_updated    => "1970-01-01",
    minimum_version => '22.1100000',
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    my $self = $class->SUPER::new($args);

    return $self;
}

sub admin {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    # Check user authorization
    my $userenv = C4::Context->userenv;
    my $is_superlibrarian = $userenv->{flags} && $userenv->{flags} == 1;

    unless ($is_superlibrarian) {
        if ( my $user_allowlist = $self->retrieve_data('user_allowlist') ) {
            my @borrowernumbers = split( /\s*,\s*/, $user_allowlist );
            my $bn              = $userenv->{number};
            unless ( grep( /^$bn$/, @borrowernumbers ) ) {
                my $t = $self->get_template( { file => 'access_denied.tt' } );
                $self->output_html( $t->output() );
                exit 0;
            }
        }
    }

    # Show the modern job management interface
    my $template = $self->get_template( { file => 'crontab.tt' } );
    $self->output_html( $template->output() );
}

sub api_routes {
    my ($self) = @_;

    my $spec_str = $self->mbf_read('api/openapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'crontab';
}

=head2 configure

  Configuration routine

=cut

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            enable_logging => $self->retrieve_data('enable_logging'),
            user_allowlist => $self->retrieve_data('user_allowlist'),
        );

        $self->output_html( $template->output() );
    } else {
        $self->store_data(
            {
                enable_logging => $cgi->param('enable_logging'),
                user_allowlist => $cgi->param('user_allowlist'),
            }
        );
        $self->go_home();
    }
}

sub install() {
    my ( $self, $args ) = @_;

    # Check if Config::Crontab is available (required for cron management)
    unless ( $self->_load_config_crontab() ) {
        warn "Config::Crontab not available - crontab management will not be available";
        warn "Please install libconfig-crontab-perl package or Config::Crontab CPAN module";
        return 0;
    }

    # Ensure backup directory exists
    my $backup_dir = $self->mbf_dir . '/backups';
    unless (-d $backup_dir) {
        require File::Path;
        File::Path::make_path($backup_dir) or do {
            warn "Failed to create backup directory: $!";
            return 0;
        };
    }

    # Store installation success
    $self->store_data( {
        installation_date => strftime("%Y-%m-%d %H:%M:%S", localtime),
    } );

    return 1;
}

sub enable {
    my ( $self ) = @_;

    # Call parent enable method
    $self->SUPER::enable();

    # Ensure Config::Crontab is loaded
    unless ( $self->_load_config_crontab() ) {
        warn "Config::Crontab not available - cannot enable crontab management";
        return;
    }

    # In crontab-primary model, jobs are added individually via the API
    # No centralized manager script needed
    # Just verify we can access the crontab

    my $ct        = Config::Crontab->new();
    my $cron_file = C4::Context->config('koha_plugin_crontab_cronfile') || undef;
    $ct->file($cron_file) if $cron_file;
    $ct->mode('block');
    $ct->read or do {
        warn "No crontab found, creating new one";
    };

    # Create a backup on enable
    my $path       = $self->mbf_dir . '/backups/';
    my $now_string = strftime "%F_%H-%M-%S", localtime;
    my $filename   = $path . 'enable_' . $now_string;

    my $backup_ct = Config::Crontab->new();
    my $backup_cron_file = C4::Context->config('koha_plugin_crontab_cronfile') || undef;
    $backup_ct->file($backup_cron_file) if $backup_cron_file;
    $backup_ct->mode('block');
    $backup_ct->read();
    $backup_ct->write("$filename");

    warn "Plugin enabled - jobs can now be managed via the web interface";

    return $self;
}

sub disable {
    my ( $self ) = @_;

    # Call parent disable method
    $self->SUPER::disable();

    # In crontab-primary model, we can optionally remove all plugin-managed jobs
    # or just leave them (they won't be editable via the UI when plugin is disabled)
    # For now, we'll leave jobs in place and just create a backup

    unless ( $self->_load_config_crontab() ) {
        warn "Config::Crontab not available during disable";
        return $self;
    }

    # Create a backup on disable
    my $path       = $self->mbf_dir . '/backups/';
    my $now_string = strftime "%F_%H-%M-%S", localtime;
    my $filename   = $path . 'disable_' . $now_string;

    my $backup_ct = Config::Crontab->new();
    my $cron_file = C4::Context->config('koha_plugin_crontab_cronfile') || undef;
    $backup_ct->file($cron_file) if $cron_file;
    $backup_ct->mode('block');
    $backup_ct->read();
    $backup_ct->write("$filename");

    warn "Plugin disabled - jobs remain in crontab but cannot be managed via UI";

    return $self;
}

sub uninstall {
    my ( $self ) = @_;

    # Remove all plugin-managed jobs from crontab
    unless ( $self->_load_config_crontab() ) {
        warn "Config::Crontab not available during uninstall";
        return 1;
    }

    require Koha::Plugin::Com::PTFSEurope::Crontab::Manager;
    my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
        backup_dir => $self->mbf_dir . '/backups',
    });

    # Create final backup before uninstall
    my $backup_file = $manager->backup_crontab();
    warn "Created final backup before uninstall: $backup_file" if $backup_file;

    # Remove all plugin-managed jobs
    my $result = $manager->safely_modify_crontab(sub {
        my ($ct) = @_;

        my @blocks_to_remove;
        for my $block ($ct->blocks) {
            my $metadata = $manager->parse_job_metadata($block);
            if ($metadata && $metadata->{'managed-by'} &&
                $metadata->{'managed-by'} eq 'koha-crontab-plugin') {
                push @blocks_to_remove, $block;
            }
        }

        for my $block (@blocks_to_remove) {
            $ct->remove($block);
        }

        warn "Removed " . scalar(@blocks_to_remove) . " plugin-managed job(s) from crontab";

        return 1;
    });

    unless ($result->{success}) {
        warn "Failed to remove plugin jobs from crontab: " . $result->{error};
    }

    return 1;
}


sub _load_config_crontab {
    my ( $self ) = @_;

    eval { require Config::Crontab; };
    return !$@;
}

1;
