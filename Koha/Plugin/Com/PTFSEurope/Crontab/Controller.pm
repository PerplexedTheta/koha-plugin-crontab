use utf8;

package Koha::Plugin::Com::PTFSEurope::Crontab::Controller;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';

use C4::Context;
use C4::Log qw( logaction );
use Koha::Plugin::Com::PTFSEurope::Crontab;
use Koha::Plugin::Com::PTFSEurope::Crontab::Manager;
use POSIX qw(strftime);
use Try::Tiny;



=head1 API

=head2 Class Methods

=head3 list

List all cron jobs

=cut

sub list {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    try {
        my $plugin = Koha::Plugin::Com::PTFSEurope::Crontab->new({});
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        my $jobs = $manager->get_plugin_managed_jobs();
        my @jobs_data = map {
            {
                id          => $_->{id},
                name        => $_->{name},
                description => $_->{description},
                schedule    => $_->{schedule},
                command     => $_->{command},
                enabled     => $_->{enabled} ? Mojo::JSON->true : Mojo::JSON->false,
                environment => $_->{environment},
                created_at  => $_->{created},
                updated_at  => $_->{updated}
            }
        } @$jobs;

        return $c->render(
            status  => 200,
            openapi => { jobs => \@jobs_data }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to fetch jobs: $_" }
        );
    };
}

=head3 get

Get a specific cron job

=cut

sub get {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    my $job_id = $c->validation->param('job_id');

    try {
        my $plugin = Koha::Plugin::Com::PTFSEurope::Crontab->new({});
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        my $jobs = $manager->get_plugin_managed_jobs();
        my ($job) = grep { $_->{id} eq $job_id } @$jobs;

        unless ($job) {
            return $c->render(
                status  => 404,
                openapi => { error => "Job not found" }
            );
        }

        return $c->render(
            status  => 200,
            openapi => {
                id          => $job->{id},
                name        => $job->{name},
                description => $job->{description},
                schedule    => $job->{schedule},
                command     => $job->{command},
                enabled     => $job->{enabled} ? Mojo::JSON->true : Mojo::JSON->false,
                environment => $job->{environment},
                created_at  => $job->{created},
                updated_at  => $job->{updated}
            }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to fetch job: $_" }
        );
    };
}

=head3 add

Create a new cron job

=cut

sub add {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    my $plugin  = Koha::Plugin::Com::PTFSEurope::Crontab->new( {} );
    my $logging = $plugin->retrieve_data('enable_logging') // 1;

    my $body = $c->req->json;

    # Validate required fields
    for my $field (qw/name schedule command/) {
        unless ($body->{$field}) {
            return $c->render(
                status  => 400,
                openapi => { error => "Missing required field: $field" }
            );
        }
    }

    try {
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        my $job_id = $manager->generate_job_id();
        my $now = strftime("%Y-%m-%d %H:%M:%S", localtime);

        my $result = $manager->safely_modify_crontab(sub {
            my ($ct) = @_;

            my $block = $manager->create_job_block({
                id          => $job_id,
                name        => $body->{name},
                description => $body->{description} || '',
                schedule    => $body->{schedule},
                command     => $body->{command},
                environment => $body->{environment},
                created     => $now,
                updated     => $now,
            });

            $ct->last($block);
            return 1;
        });

        unless ($result->{success}) {
            die $result->{error};
        }

        logaction( 'SYSTEMPREFERENCE', 'ADD', $job_id, "CrontabPlugin: Created job '" . $body->{name} . "'" ) if $logging;

        return $c->render(
            status  => 201,
            openapi => {
                id          => $job_id,
                name        => $body->{name},
                description => $body->{description} || '',
                schedule    => $body->{schedule},
                command     => $body->{command},
                enabled     => Mojo::JSON->true,
                environment => $body->{environment} || {},
                created_at  => $now,
                updated_at  => $now
            }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to create job: $_" }
        );
        };
}

=head3 update

Update an existing cron job

=cut

sub update {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    my $plugin  = Koha::Plugin::Com::PTFSEurope::Crontab->new( {} );
    my $logging = $plugin->retrieve_data('enable_logging') // 1;

    my $job_id = $c->validation->param('job_id');
    my $body   = $c->req->json;

    try {
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        my $updated_job;

        my $result = $manager->safely_modify_crontab(sub {
            my ($ct) = @_;

            my $block = $manager->find_job_block($ct, $job_id);
            unless ($block) {
                die "Job not found";
            }

            # Build updates hash from body
            my %updates;
            $updates{name} = $body->{name} if defined $body->{name};
            $updates{description} = $body->{description} if defined $body->{description};
            $updates{schedule} = $body->{schedule} if defined $body->{schedule};
            $updates{command} = $body->{command} if defined $body->{command};
            $updates{environment} = $body->{environment} if defined $body->{environment};

            $manager->update_job_block($block, \%updates);

            # Get updated job data for response
            my $metadata = $manager->parse_job_metadata($block);
            my @events = $block->select(-type => 'event');
            my %env;
            for my $env_var ($block->select(-type => 'env')) {
                $env{$env_var->name} = $env_var->value;
            }

            $updated_job = {
                id          => $metadata->{'crontab-manager-id'},
                name        => $metadata->{name} || '',
                description => $metadata->{description} || '',
                schedule    => $events[0] ? $events[0]->datetime : '',
                command     => $events[0] ? $events[0]->command : '',
                enabled     => @events ? 1 : 0,
                environment => \%env,
                created_at  => $metadata->{created} || '',
                updated_at  => $metadata->{updated} || '',
            };

            return 1;
        });

        unless ($result->{success}) {
            if ($result->{error} =~ /Job not found/) {
                return $c->render(
                    status  => 404,
                    openapi => { error => "Job not found" }
                );
            }
            die $result->{error};
        }

        logaction( 'SYSTEMPREFERENCE', 'MODIFY', $job_id, "CrontabPlugin: Updated job '" . $updated_job->{name} . "'" ) if $logging;

        return $c->render(
            status  => 200,
            openapi => {
                id          => $updated_job->{id},
                name        => $updated_job->{name},
                description => $updated_job->{description},
                schedule    => $updated_job->{schedule},
                command     => $updated_job->{command},
                enabled     => $updated_job->{enabled} ? Mojo::JSON->true : Mojo::JSON->false,
                environment => $updated_job->{environment},
                created_at  => $updated_job->{created_at},
                updated_at  => $updated_job->{updated_at}
            }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to update job: $_" }
        );
        };
}

=head3 delete

Delete a cron job

=cut

sub delete {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    my $plugin  = Koha::Plugin::Com::PTFSEurope::Crontab->new( {} );
    my $logging = $plugin->retrieve_data('enable_logging') // 1;

    my $job_id = $c->validation->param('job_id');

    try {
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        my $job_name;

        my $result = $manager->safely_modify_crontab(sub {
            my ($ct) = @_;

            my $block = $manager->find_job_block($ct, $job_id);
            unless ($block) {
                die "Job not found";
            }

            # Get job name before deletion for logging
            my $metadata = $manager->parse_job_metadata($block);
            $job_name = $metadata->{name} || '';

            # Remove the block from crontab
            $ct->remove($block);

            return 1;
        });

        unless ($result->{success}) {
            if ($result->{error} =~ /Job not found/) {
                return $c->render(
                    status  => 404,
                    openapi => { error => "Job not found" }
                );
            }
            die $result->{error};
        }

        logaction( 'SYSTEMPREFERENCE', 'DELETE', $job_id, "CrontabPlugin: Deleted job '$job_name'" ) if $logging;

        return $c->render(
            status  => 204,
            openapi => { success => Mojo::JSON->true }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to delete job: $_" }
        );
    };
}

=head3 enable

Enable a cron job

=cut

sub enable {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    my $plugin  = Koha::Plugin::Com::PTFSEurope::Crontab->new( {} );
    my $logging = $plugin->retrieve_data('enable_logging') // 1;

    my $job_id = $c->validation->param('job_id');

    try {
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        my $job_name;

        my $result = $manager->safely_modify_crontab(sub {
            my ($ct) = @_;

            my $block = $manager->find_job_block($ct, $job_id);
            unless ($block) {
                die "Job not found";
            }

            my $metadata = $manager->parse_job_metadata($block);
            $job_name = $metadata->{name} || '';

            # Enable event by setting active flag
            my @events = $block->select(-type => 'event');
            for my $event (@events) {
                $event->active(1);
            }

            return 1;
        });

        unless ($result->{success}) {
            if ($result->{error} =~ /Job not found/) {
                return $c->render(
                    status  => 404,
                    openapi => { error => "Job not found" }
                );
            }
            die $result->{error};
        }

        logaction( 'SYSTEMPREFERENCE', 'MODIFY', $job_id, "CrontabPlugin: Enabled job '$job_name'" ) if $logging;

        return $c->render(
            status  => 200,
            openapi => { success => Mojo::JSON->true }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to enable job: $_" }
        );
        };
}

=head3 disable

Disable a cron job

=cut

sub disable {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    my $plugin  = Koha::Plugin::Com::PTFSEurope::Crontab->new( {} );
    my $logging = $plugin->retrieve_data('enable_logging') // 1;

    my $job_id = $c->validation->param('job_id');

    try {
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        my $job_name;

        my $result = $manager->safely_modify_crontab(sub {
            my ($ct) = @_;

            my $block = $manager->find_job_block($ct, $job_id);
            unless ($block) {
                die "Job not found";
            }

            my $metadata = $manager->parse_job_metadata($block);
            $job_name = $metadata->{name} || '';

            # Disable event by setting active flag to 0
            my @events = $block->select(-type => 'event');
            for my $event (@events) {
                $event->active(0);
            }

            return 1;
        });

        unless ($result->{success}) {
            if ($result->{error} =~ /Job not found/) {
                return $c->render(
                    status  => 404,
                    openapi => { error => "Job not found" }
                );
            }
            die $result->{error};
        }

        logaction( 'SYSTEMPREFERENCE', 'MODIFY', $job_id, "CrontabPlugin: Disabled job '$job_name'" ) if $logging;

        return $c->render(
            status  => 200,
            openapi => { success => Mojo::JSON->true }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to disable job: $_" }
        );
        };
}

=head3 backup

Create a backup of current job configuration

=cut

sub backup {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    my $plugin = Koha::Plugin::Com::PTFSEurope::Crontab->new;

    try {
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        # This creates a crontab backup file
        my $backup_file = $manager->backup_crontab();

        unless ($backup_file) {
            die "Failed to create backup";
        }

        # Extract just the filename from the full path
        my $filename = (split('/', $backup_file))[-1];

        return $c->render(
            status  => 200,
            openapi => { filename => $filename }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to create backup: $_" }
        );
    };
}

=head3 list_all

List all crontab entries (both plugin-managed and system jobs)

=cut

sub list_all {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    try {
        my $plugin = Koha::Plugin::Com::PTFSEurope::Crontab->new({});
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        my $entries = $manager->get_all_crontab_entries();
        my @entries_data = map {
            my $entry = {
                schedule => $_->{schedule},
                command => $_->{command},
                enabled => $_->{enabled} ? Mojo::JSON->true : Mojo::JSON->false,
                managed => $_->{managed} ? Mojo::JSON->true : Mojo::JSON->false,
                comments => $_->{comments} || [],
            };

            # Add managed job fields if applicable
            if ($_->{managed}) {
                $entry->{id} = $_->{id};
                $entry->{name} = $_->{name};
                $entry->{description} = $_->{description};
                $entry->{created_at} = $_->{created};
                $entry->{updated_at} = $_->{updated};
            }

            $entry;
        } @$entries;

        return $c->render(
            status  => 200,
            openapi => { entries => \@entries_data }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to fetch crontab entries: $_" }
        );
    };
}

=head3 get_environment

Get global environment variables from the crontab

=cut

sub get_environment {
    my $c = shift->openapi->valid_input or return;

    if ( my $r = check_user_allowlist($c) ) { return $r; }

    try {
        my $plugin = Koha::Plugin::Com::PTFSEurope::Crontab->new({});
        my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
            backup_dir => $plugin->mbf_dir . '/backups',
        });

        my $env = $manager->get_global_environment();

        return $c->render(
            status  => 200,
            openapi => { environment => $env }
        );
    } catch {
        return $c->render(
            status  => 500,
            openapi => { error => "Failed to fetch environment: $_" }
        );
    };
}

sub check_user_allowlist {
    my ($c) = @_;

    my $plugin = Koha::Plugin::Com::PTFSEurope::Crontab->new({});
    my $user_allowlist = $plugin->retrieve_data('user_allowlist');

    if ( $user_allowlist ) {
        my @borrowernumbers = split( /\s*,\s*/, $user_allowlist );

        # Check if user is logged in
        my $userenv = C4::Context->userenv;
        unless ($userenv && $userenv->{number}) {
            return $c->render(
                status  => 401,
                openapi => { error => "Authentication required" }
            );
        }

        my $bn = $userenv->{number};
        if ( grep( /^$bn$/, @borrowernumbers ) ) {
            return undef;
        } else {
            return $c->render(
                status  => 401,
                openapi => { error => "You are not authorised to use this plugin" }
            );
        }
    }

    # If no allowlist is configured, allow access
    return undef;
}

1;
