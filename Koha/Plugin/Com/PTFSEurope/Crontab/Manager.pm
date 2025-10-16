package Koha::Plugin::Com::PTFSEurope::Crontab::Manager;

# Core infrastructure module for safe crontab manipulation

use Modern::Perl;
use Fcntl qw(:flock);
use POSIX qw(strftime);
use Try::Tiny;
use File::Spec;
use File::Path qw(make_path);
use File::Find;
use Data::UUID;
use Config::Crontab;
use C4::Context;
use Pod::Usage;
use File::Basename;

=head1 NAME

Koha::Plugin::Com::PTFSEurope::Crontab::Manager - Core crontab management with safety features

=head1 SYNOPSIS

    my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
        backup_dir => '/path/to/backups',
        lock_timeout => 10,
    });

    my $result = $manager->safely_modify_crontab(sub {
        my ($ct) = @_;
        # Make modifications to $ct here
        # ...
        return 1; # Success
    });

=head1 DESCRIPTION

This module provides safe crontab manipulation with file locking, automatic backups,
validation, and metadata parsing.

=head1 METHODS

=cut

=head2 new

Constructor

    my $manager = Koha::Plugin::Com::PTFSEurope::Crontab::Manager->new({
        backup_dir => '/path/to/backups',     # Directory for backup files
        lock_timeout => 10,                    # Lock timeout in seconds (default: 10)
        backup_retention => 10,                # Number of backups to keep (default: 10)
    });

=cut

sub new {
    my ( $class, $args ) = @_;

    my $self = {
        backup_dir   => $args->{backup_dir}   || '/tmp/koha-crontab-backups',
        lock_timeout => $args->{lock_timeout} || 10,
        backup_retention => $args->{backup_retention} || 10,
        lockfile         => '/tmp/koha-crontab-plugin.lock',
        uuid_generator   => Data::UUID->new(),
    };

    bless $self, $class;

    # Ensure backup directory exists
    unless ( -d $self->{backup_dir} ) {
        make_path( $self->{backup_dir} )
          or die "Cannot create backup directory $self->{backup_dir}: $!";
    }

    return $self;
}

=head2 safely_modify_crontab

Safely modify the crontab with file locking, backups, and validation

    my $result = $manager->safely_modify_crontab(sub {
        my ($ct) = @_;
        # Make modifications to $ct here
        my $block = $manager->create_job_block({
            id => $manager->generate_job_id(),
            name => 'Test Job',
            description => 'A test job',
            schedule => '0 2 * * *',
            command => '/bin/echo "test"',
        });
        $ct->last($block);
        return 1;
    });

    if ($result->{success}) {
        print "Modification successful\n";
    } else {
        print "Error: $result->{error}\n";
    }

=cut

sub safely_modify_crontab {
    my ( $self, $modification_callback ) = @_;

    # Acquire exclusive lock
    my $lock_fh = $self->_acquire_lock();
    unless ($lock_fh) {
        return {
            success => 0,
            error   =>
"Could not acquire lock (another operation in progress or timeout)"
        };
    }

    my $result = eval {

        # 1. Create backup of current crontab
        my $backup_file = $self->backup_crontab();
        unless ($backup_file) {
            die "Failed to create backup\n";
        }

        # 2. Read and parse current crontab
        my $ct = $self->_read_crontab();
        unless ($ct) {
            die "Failed to read crontab\n";
        }

        # 3. Pre-modification validation
        unless ( $self->validate_crontab($ct) ) {
            die "Pre-modification validation failed\n";
        }

        # 4. Apply modifications via callback
        my $callback_result = $modification_callback->($ct);
        unless ($callback_result) {
            die "Modification callback returned failure\n";
        }

        # 5. Dry-run validation (parse the string we'll write)
        my $draft   = $ct->dump();
        my $test_ct = Config::Crontab->new();
        $test_ct->parse($draft);
        unless ( $self->validate_crontab($test_ct) ) {
            die "Post-modification validation failed\n";
        }

        # 6. Write atomically
        my $cron_file =
          C4::Context->config('koha_plugin_crontab_cronfile') || undef;
        $ct->file($cron_file) if $cron_file;
        $ct->write();

        return {
            success => 1,
            backup  => $backup_file,
            message => "Crontab modified successfully"
        };
    };

    if ($@) {

        # Restore from backup on failure
        my $restore_result = $self->restore_crontab();
        $result = {
            success  => 0,
            error    => "Modification failed: $@",
            restored => $restore_result,
        };
    }

    # Release lock
    $self->_release_lock($lock_fh);

    return $result;
}

=head2 backup_crontab

Create a backup of the current crontab file

Returns the backup filename on success, undef on failure

=cut

sub backup_crontab {
    my ($self) = @_;

    my $now_string = strftime "%Y-%m-%d_%H-%M-%S", localtime;
    my $filename =
      File::Spec->catfile( $self->{backup_dir}, "crontab_backup_$now_string" );

    try {
        my $ct = Config::Crontab->new();
        my $cron_file =
          C4::Context->config('koha_plugin_crontab_cronfile') || undef;
        $ct->file($cron_file) if $cron_file;
        $ct->read();
        $ct->write($filename);

        # Cleanup old backups
        $self->_cleanup_old_backups();

        return $filename;
    }
    catch {
        warn "Failed to create backup: $_";
        return undef;
    };
}

=head2 restore_crontab

Restore the most recent crontab backup

Returns 1 on success, 0 on failure

=cut

sub restore_crontab {
    my ( $self, $specific_backup ) = @_;

    my $backup_file;

    if ($specific_backup) {
        $backup_file = $specific_backup;
    }
    else {
        # Find the most recent backup
        $backup_file = $self->_get_latest_backup();
    }

    unless ( $backup_file && -f $backup_file ) {
        warn "No backup file found to restore";
        return 0;
    }

    try {
        my $ct = Config::Crontab->new();
        $ct->read($backup_file);

        my $cron_file =
          C4::Context->config('koha_plugin_crontab_cronfile') || undef;
        $ct->file($cron_file) if $cron_file;
        $ct->write();

        return 1;
    }
    catch {
        warn "Failed to restore from backup $backup_file: $_";
        return 0;
    };
}

=head2 list_backups

Get a list of available backup files, sorted by date (newest first)

Returns an arrayref of hashrefs with 'filename' and 'timestamp' keys

=cut

sub list_backups {
    my ($self) = @_;

    opendir( my $dh, $self->{backup_dir} ) or return [];
    my @backups = grep {
        /^crontab_backup_/ && -f File::Spec->catfile( $self->{backup_dir}, $_ )
    } readdir($dh);
    closedir($dh);

    # Sort by date (newest first)
    @backups = sort { $b cmp $a } @backups;

    my @result;
    for my $backup (@backups) {
        my $fullpath = File::Spec->catfile( $self->{backup_dir}, $backup );
        my $mtime    = ( stat($fullpath) )[9];
        push @result,
          {
            filename  => $fullpath,
            timestamp => $mtime,
            display   => strftime( "%Y-%m-%d %H:%M:%S", localtime($mtime) ),
          };
    }

    return \@result;
}

=head2 parse_job_metadata

Parse metadata from comment block above a cron entry

    my $metadata = $manager->parse_job_metadata($block);

Returns hashref with metadata, or undef if not a plugin-managed job

=cut

sub parse_job_metadata {
    my ( $self, $block ) = @_;

    my %metadata;
    my @comments = $block->select( -type => 'comment' );

    for my $comment (@comments) {
        my $data = $comment->data();

        # Parse structured metadata (@key: value format)
        if ( $data =~ /^\s*#\s*\@(\w+(?:-\w+)*):\s*(.+)\s*$/ ) {
            my ( $key, $value ) = ( $1, $2 );
            $metadata{$key} = $value;
        }
    }

    # Only consider this job manageable if it has our ID marker
    return undef unless $metadata{'crontab-manager-id'};

    return \%metadata;
}

=head2 create_job_block

Create a crontab block with metadata for a job

    my $block = $manager->create_job_block({
        id => $uuid,
        name => 'Job Name',
        description => 'Job description',
        schedule => '0 2 * * *',
        command => '/path/to/command',
        environment => { VAR1 => 'value1' }, # optional
        created => '2025-10-15 10:00:00',    # optional, defaults to now
        updated => '2025-10-15 10:00:00',    # optional, defaults to now
    });

=cut

sub create_job_block {
    my ( $self, $job_data ) = @_;

    my $now = strftime( "%Y-%m-%d %H:%M:%S", localtime );

    my $block = Config::Crontab::Block->new();
    my @lines;

    # Add metadata as comments
    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@crontab-manager-id: " . $job_data->{id} );

    push @lines,
      Config::Crontab::Comment->new( -data => "# \@name: " . $job_data->{name} )
      if $job_data->{name};

    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@description: " . $job_data->{description} )
      if $job_data->{description};

    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@created: " . ( $job_data->{created} || $now ) );

    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@updated: " . ( $job_data->{updated} || $now ) );

    push @lines,
      Config::Crontab::Comment->new(
        -data => "# \@managed-by: koha-crontab-plugin" );

    # Add environment variables if present
    if ( $job_data->{environment} && ref( $job_data->{environment} ) eq 'HASH' )
    {
        for my $key ( sort keys %{ $job_data->{environment} } ) {
            my $value = $job_data->{environment}->{$key};
            push @lines,
              Config::Crontab::Env->new(
                -name  => $key,
                -value => $value
              );
        }
    }

    # Add the cron entry with active flag based on enabled status
    my $event = Config::Crontab::Event->new(
        -datetime => $job_data->{schedule},
        -command  => $job_data->{command}
    );

    # Set active flag (1 = enabled/uncommented, 0 = disabled/commented)
    my $enabled = defined $job_data->{enabled} ? $job_data->{enabled} : 1;
    $event->active($enabled);

    push @lines, $event;

    $block->lines( \@lines );

    return $block;
}

=head2 get_plugin_managed_jobs

Get all jobs managed by this plugin from the crontab

Returns an arrayref of hashrefs containing job data

=cut

sub get_plugin_managed_jobs {
    my ($self) = @_;

    my $ct = $self->_read_crontab();
    return [] unless $ct;

    my @jobs;

    for my $block ( $ct->blocks ) {
        my $metadata = $self->parse_job_metadata($block);
        next unless $metadata;
        next
          unless $metadata->{'managed-by'}
          && $metadata->{'managed-by'} eq 'koha-crontab-plugin';

        # Extract the cron event from the block
        my @events = $block->select( -type => 'event' );
        next unless @events;

        my $event = $events[0];    # Take first event in block

        # Extract environment variables
        my %environment;
        for my $env ( $block->select( -type => 'env' ) ) {
            $environment{ $env->name } = $env->value;
        }

        my $job = {
            id          => $metadata->{'crontab-manager-id'},
            name        => $metadata->{name}        || '',
            description => $metadata->{description} || '',
            schedule    => $event->datetime,
            command     => $event->command,
            environment => \%environment,
            created     => $metadata->{created} || '',
            updated     => $metadata->{updated} || '',
            enabled     => $event->active
            ? 1
            : 0,    # Check active flag (1 = uncommented, 0 = commented)
        };

        push @jobs, $job;
    }

    return \@jobs;
}

=head2 get_all_crontab_entries

Get ALL entries from the crontab (plugin-managed + system)

Returns an arrayref of hashrefs with job data and a 'managed' flag

=cut

sub get_all_crontab_entries {
    my ($self) = @_;

    my $ct = $self->_read_crontab();
    return [] unless $ct;

    my @entries;

    for my $block ( $ct->blocks ) {
        my $metadata = $self->parse_job_metadata($block);
        my $is_managed =
             $metadata
          && $metadata->{'managed-by'}
          && $metadata->{'managed-by'} eq 'koha-crontab-plugin';

        # Extract the cron event from the block
        my @events = $block->select( -type => 'event' );
        next unless @events;

        my $event = $events[0];

        # Get any comments for system entries
        my @comments     = $block->select( -type => 'comment' );
        my @comment_text = map { $_->data } @comments;

        my $entry = {
            schedule => $event->datetime,
            command  => $event->command,
            managed  => $is_managed    ? 1 : 0,
            enabled  => $event->active ? 1 : 0,
            comments => \@comment_text,
        };

        # Add metadata if plugin-managed
        if ($is_managed) {
            $entry->{id}          = $metadata->{'crontab-manager-id'};
            $entry->{name}        = $metadata->{name}        || '';
            $entry->{description} = $metadata->{description} || '';
            $entry->{created}     = $metadata->{created}     || '';
            $entry->{updated}     = $metadata->{updated}     || '';
        }

        push @entries, $entry;
    }

    return \@entries;
}

=head2 get_global_environment

Get global environment variables from the crontab

Returns a hashref of environment variable name => value pairs

=cut

sub get_global_environment {
    my ($self) = @_;

    my $ct = $self->_read_crontab();
    return {} unless $ct;

    my %env;

    # Get global environment variables (not inside blocks)
    my @lines = $ct->select( -type => 'env' );
    for my $line (@lines) {
        next unless $line && ref($line);
        $env{ $line->name } = $line->value;
    }

    return \%env;
}

=head2 validate_crontab

Validate a crontab object

    my $is_valid = $manager->validate_crontab($ct);

Returns 1 if valid, 0 if invalid

=cut

sub validate_crontab {
    my ( $self, $ct ) = @_;

    return 0 unless $ct;

    try {
        # Test that we can dump the crontab (catches syntax errors)
        my $dump = $ct->dump();

        # Validate that we can parse what we dumped
        my $test_ct = Config::Crontab->new();
        $test_ct->parse($dump);

        # Validate all events have valid cron syntax
        for my $block ( $ct->blocks ) {
            for my $event ( $block->select( -type => 'event' ) ) {
                my $datetime = $event->datetime;

                # Basic cron syntax validation (5 fields)
                my @fields = split /\s+/, $datetime;
                unless ( @fields == 5 ) {
                    warn
                      "Invalid cron datetime (must have 5 fields): $datetime";
                    return 0;
                }

                # Validate each field has allowed characters
                for my $field (@fields) {
                    unless ( $field =~ /^[\d\*\/\-\,]+$/ ) {
                        warn "Invalid cron field: $field";
                        return 0;
                    }
                }
            }
        }

        return 1;
    }
    catch {
        warn "Crontab validation failed: $_";
        return 0;
    };
}

=head2 generate_job_id

Generate a unique UUID for a job

    my $uuid = $manager->generate_job_id();

=cut

sub generate_job_id {
    my ($self) = @_;

    return $self->{uuid_generator}->create_str();
}

=head2 find_job_block

Find a job block by ID

    my $block = $manager->find_job_block($ct, $job_id);

Returns the block if found, undef otherwise

=cut

sub find_job_block {
    my ( $self, $ct, $job_id ) = @_;

    for my $block ( $ct->blocks ) {
        my $metadata = $self->parse_job_metadata($block);
        next unless $metadata;

        if ( $metadata->{'crontab-manager-id'} eq $job_id ) {
            return $block;
        }
    }

    return undef;
}

=head2 update_job_block

Update an existing job block with new data

    my $success = $manager->update_job_block($block, {
        name => 'New Name',
        description => 'New description',
        schedule => '0 3 * * *',
        command => '/new/command',
    });

=cut

sub update_job_block {
    my ( $self, $block, $updates ) = @_;

    # Get existing metadata
    my $metadata = $self->parse_job_metadata($block);
    return 0 unless $metadata;

    # Create updated block
    my $job_data = {
        id          => $metadata->{'crontab-manager-id'},
        name        => $updates->{name}        // $metadata->{name},
        description => $updates->{description} // $metadata->{description},
        schedule    => $updates->{schedule}    // '',
        command     => $updates->{command}     // '',
        environment => $updates->{environment},
        created     => $metadata->{created},
        updated     => strftime( "%Y-%m-%d %H:%M:%S", localtime ),
    };

    # If schedule/command not provided in updates, extract from existing block
    unless ( $job_data->{schedule} ) {
        my @events = $block->select( -type => 'event' );
        $job_data->{schedule} = $events[0]->datetime if @events;
    }

    unless ( $job_data->{command} ) {
        my @events = $block->select( -type => 'event' );
        $job_data->{command} = $events[0]->command if @events;
    }

    # Get existing environment if not provided
    unless ( $job_data->{environment} ) {
        my %env;
        for my $env_var ( $block->select( -type => 'env' ) ) {
            $env{ $env_var->name } = $env_var->value;
        }
        $job_data->{environment} = \%env if %env;
    }

    # Create new block
    my $new_block = $self->create_job_block($job_data);

    # Replace lines in the existing block
    $block->lines( $new_block->lines );

    return 1;
}

=head2 get_available_scripts

Get list of available scripts from KOHA_CRON_PATH

    my $scripts = $manager->get_available_scripts();

Returns arrayref of hashrefs with script metadata

=cut

sub get_available_scripts {
    my ($self) = @_;

    # Get KOHA_CRON_PATH from crontab environment
    my $ct = $self->_read_crontab();
    return [] unless $ct;

    my $cron_path;
    my @env_lines = $ct->select( -type => 'env' );
    for my $env (@env_lines) {
        if ( $env->name eq 'KOHA_CRON_PATH' ) {
            $cron_path = $env->value;
            last;
        }
    }

    return [] unless $cron_path && -d $cron_path;

    my @scripts;
    find(
        sub {
            my $abs_path = $File::Find::name;
            my $rel_path = $abs_path;
            $rel_path =~ s/^\Q$cron_path\E//;
            $rel_path = '$KOHA_CRON_PATH' . $rel_path;

            # Only include .pl and .sh files
            if ( -f $abs_path
                && ( $abs_path =~ /\.pl$/ || $abs_path =~ /\.sh$/ ) )
            {
                my $type     = $abs_path =~ /\.pl$/ ? 'perl' : 'shell';
                my $basename = basename($abs_path);

                # Get brief description from POD NAME section for perl scripts
                my $description = '';
                if ( $type eq 'perl' ) {
                    my $doc = $self->parse_script_documentation($abs_path);
                    $description = $doc->{name_brief} || '';
                }

                push @scripts,
                  {
                    name          => $basename,
                    path          => $abs_path,
                    relative_path => $rel_path,
                    type          => $type,
                    description   => $description,
                  };
            }
        },
        $cron_path
    );

    # Sort by name
    @scripts = sort { $a->{name} cmp $b->{name} } @scripts;

    return \@scripts;
}

=head2 parse_script_documentation

Parse POD documentation from a Perl script using Pod::Usage

    my $doc = $manager->parse_script_documentation('/path/to/script.pl');

Returns hashref with: name_brief, usage_text

=cut

sub parse_script_documentation {
    my ( $self, $script_path ) = @_;

    return {} unless -f $script_path;

    my %doc = (
        name_brief => '',
        usage_text => '',
    );

    # Extract brief description from NAME section
    try {
        my $name_output = '';
        open my $name_fh, '>', \$name_output;
        pod2usage(
            -input    => $script_path,
            -output   => $name_fh,
            -sections => 'DESCRIPTION',
            -verbose  => 99,
            -exitval  => 'NOEXIT'
        );
        close $name_fh;

        $doc{name_brief} = $name_output;
    }
    catch {
        # If NAME section fails, that's okay
    };

    # Extract full usage documentation (verbose level 2 shows all sections)
    try {
        my $usage_output = '';
        open my $usage_fh, '>', \$usage_output;
        pod2usage(
            -input   => $script_path,
            -output  => $usage_fh,
            -verbose => 1,
            -exitval => 'NOEXIT'
        );
        close $usage_fh;

        $doc{usage_text} = $usage_output;
    }
    catch {
        warn "Failed to extract POD from $script_path: $_";
        $doc{usage_text} = "No documentation available.\n";
    };

    return \%doc;
}

=head2 parse_script_options

Parse command-line options from a Perl script's GetOptions call

    my $options = $manager->parse_script_options('/path/to/script.pl');

Returns arrayref of hashrefs with: name, short_name, type, description, required

=cut

sub parse_script_options {
    my ( $self, $script_path ) = @_;

    return [] unless -f $script_path;

    # Parse GetOptions from the script itself to get option names and types
    my @options;
    open my $fh, '<', $script_path or return [];
    my $in_getoptions    = 0;
    my $getoptions_block = '';

    while ( my $line = <$fh> ) {
        if ( $line =~ /GetOptions\s*\(/i ) {
            $in_getoptions = 1;
        }

        if ($in_getoptions) {
            $getoptions_block .= $line;
            if ( $line =~ /\)\s*;/ || $line =~ /\|\|\s*pod2usage/ ) {
                last;
            }
        }
    }
    close $fh;

    # Parse option specifications from GetOptions block
    while ( $getoptions_block =~ /'([^']+)'\s*=>/g ) {
        my $spec = $1;
        my ( $name, $short_name, $type, $required ) = ( '', '', 'boolean', 0 );

        # Parse spec format: 'name|alias:type'
        if ( $spec =~ /^([\w-]+)(?:\|(\w+))?(?:([=:])(\w+))?$/ ) {
            $name       = $1;
            $short_name = $2 || '';
            my $modifier  = $3 || '';
            my $type_code = $4 || '';

            # Determine type
            if ( $modifier eq '=' ) {
                $required = 1;
                if ( $type_code eq 's' ) {
                    $type = 'string';
                }
                elsif ( $type_code eq 'i' ) {
                    $type = 'integer';
                }
                elsif ( $type_code eq 'f' ) {
                    $type = 'float';
                }
            }
            elsif ( $modifier eq ':' ) {
                $required = 0;
                if ( $type_code eq 's' ) {
                    $type = 'string';
                }
                elsif ( $type_code eq 'i' ) {
                    $type = 'integer';
                }
                elsif ( $type_code eq 'f' ) {
                    $type = 'float';
                }
            }

            push @options,
              {
                name       => $name,
                short_name => $short_name,
                type       => $type,
                required   => $required,
              };
        }
    }

    return \@options;
}

#
# Private methods
#

sub _acquire_lock {
    my ($self) = @_;

    open my $lock_fh, '>', $self->{lockfile} or do {
        warn "Cannot create lockfile: $!";
        return undef;
    };

    my $timeout = $self->{lock_timeout};
    my $locked  = 0;

    eval {
        local $SIG{ALRM} = sub { die "Lock timeout\n" };
        alarm($timeout);
        flock( $lock_fh, LOCK_EX ) or die "Cannot lock: $!";
        $locked = 1;
        alarm(0);
    };

    if ( !$locked ) {
        close $lock_fh;
        warn "Failed to acquire lock: $@" if $@;
        return undef;
    }

    return $lock_fh;
}

sub _release_lock {
    my ( $self, $lock_fh ) = @_;

    return unless $lock_fh;

    flock( $lock_fh, LOCK_UN );
    close $lock_fh;
}

sub _read_crontab {
    my ($self) = @_;

    try {
        my $ct = Config::Crontab->new();
        my $cron_file =
          C4::Context->config('koha_plugin_crontab_cronfile') || undef;
        $ct->file($cron_file) if $cron_file;
        $ct->mode('block');
        $ct->read();
        return $ct;
    }
    catch {
        warn "Failed to read crontab: $_";
        return undef;
    };
}

sub _get_latest_backup {
    my ($self) = @_;

    my $backups = $self->list_backups();
    return undef unless @$backups;

    return $backups->[0]->{filename};
}

sub _cleanup_old_backups {
    my ($self) = @_;

    my $backups   = $self->list_backups();
    my $retention = $self->{backup_retention};

    # Remove backups beyond retention limit
    if ( @$backups > $retention ) {
        my @to_remove = @$backups[ $retention .. $#$backups ];
        for my $backup (@to_remove) {
            unlink $backup->{filename}
              or warn "Failed to remove old backup $backup->{filename}: $!";
        }
    }
}

1;

=head1 AUTHOR

Martin Renvoize <martin.renvoize@openfifth.co.uk>

=head1 COPYRIGHT

Copyright 2025 PTFS Europe

=head1 LICENSE

This file is part of Koha.

Koha is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 3 of the License, or (at your option) any later version.

=cut
