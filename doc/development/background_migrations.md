# Background Migrations

Background migrations can be used to perform data migrations that would
otherwise take a very long time (hours, days, years, etc) to complete. For
example, you can use background migrations to migrate data so that instead of
storing data in a single JSON column the data is stored in a separate table.

## When To Use Background Migrations

In the vast majority of cases you will want to use a regular Rails migration
instead. Background migrations should _only_ be used when migrating _data_ in
tables that have so many rows this process would take hours when performed in a
regular Rails migration.

Background migrations _may not_ be used to perform schema migrations, they
should only be used for data migrations.

Some examples where background migrations can be useful:

* Migrating events from one table to multiple separate tables.
* Populating one column based on JSON stored in another column.
* Migrating data that depends on the output of exernal services (e.g. an API).

## Isolation

Background migrations must be isolated and can not use application code (e.g.
models defined in `app/models`). Since these migrations can take a long time to
run it's possible for new versions to be deployed while they are still running.

It's also possible for different migrations to be executed at the same time.
This means that different background migrations should not migrate data in a
way that would cause conflicts.

## How It Works

Background migrations are simple classes that define a `perform` method. A
Sidekiq worker will then execute such a class, passing any arguments to it. All
migration classes must be defined in the namespace
`Gitlab::BackgroundMigration`, the files should be placed in the directory
`lib/gitlab/background_migration/`.

## Scheduling

Scheduling a migration can be done in either a regular migration or a
post-deployment migration. To do so, simply use the following code while
replacing the class name and arguments with whatever values are necessary for
your migration:

```ruby
BackgroundMigrationWorker.perform_async('BackgroundMigrationClassName', [arg1, arg2, ...])
```

Usually it's better to enqueue jobs in bulk, for this you can use
`BackgroundMigrationWorker.perform_bulk`:

```ruby
BackgroundMigrationWorker.perform_bulk(
  [['BackgroundMigrationClassName', [1]],
   ['BackgroundMigrationClassName', [2]]]
)
```

You'll also need to make sure that newly created data is either migrated, or
saved in both the old and new version upon creation. For complex and time
consuming migrations it's best to schedule a background job using an
`after_create` hook so this doesn't affect response timings. The same applies to
updates. Removals in turn can be handled by simply defining foreign keys with
cascading deletes.

If you would like to schedule jobs in bulk with a delay, you can use
`BackgroundMigrationWorker.perform_bulk_in`:

```ruby
jobs = [['BackgroundMigrationClassName', [1]],
        ['BackgroundMigrationClassName', [2]]]

BackgroundMigrationWorker.perform_bulk_in(5.minutes, jobs)
```

## Cleaning Up

Because background migrations can take a long time you can't immediately clean
things up after scheduling them. For example, you can't drop a column that's
used in the migration process as this would cause jobs to fail. This means that
you'll need to add a separate _post deployment_ migration in a future release
that finishes any remaining jobs before cleaning things up (e.g. removing a
column).

As an example, say you want to migrate the data from column `foo` (containing a
big JSON blob) to column `bar` (containing a string). The process for this would
roughly be as follows:

1. Release A:
  1. Create a migration class that perform the migration for a row with a given ID.
  1. Deploy the code for this release, this should include some code that will
     schedule jobs for newly created data (e.g. using an `after_create` hook).
  1. Schedule jobs for all existing rows in a post-deployment migration. It's
     possible some newly created rows may be scheduled twice so your migration
     should take care of this.
1. Release B:
  1. Deploy code so that the application starts using the new column and stops
     scheduling jobs for newly created data.
  1. In a post-deployment migration you'll need to ensure no jobs remain. To do
     so you can use `Gitlab::BackgroundMigration.steal` to process any remaining
     jobs before continueing.
  1. Remove the old column.

## Example

To explain all this, let's use the following example: the table `services` has a
field called `properties` which is stored in JSON. For all rows you want to
extract the `url` key from this JSON object and store it in the `services.url`
column. There are millions of services and parsing JSON is slow, thus you can't
do this in a regular migration.

To do this using a background migration we'll start with defining our migration
class:

```ruby
class Gitlab::BackgroundMigration::ExtractServicesUrl
  class Service < ActiveRecord::Base
    self.table_name = 'services'
  end

  def perform(service_id)
    # A row may be removed between scheduling and starting of a job, thus we
    # need to make sure the data is still present before doing any work.
    service = Service.select(:properties).find_by(id: service_id)

    return unless service

    begin
      json = JSON.load(service.properties)
    rescue JSON::ParserError
      # If the JSON is invalid we don't want to keep the job around forever,
      # instead we'll just leave the "url" field to whatever the default value
      # is.
      return
    end

    service.update(url: json['url']) if json['url']
  end
end
```

Next we'll need to adjust our code so we schedule the above migration for newly
created and updated services. We can do this using something along the lines of
the following:

```ruby
class Service < ActiveRecord::Base
  after_commit :schedule_service_migration, on: :update
  after_commit :schedule_service_migration, on: :create

  def schedule_service_migration
    BackgroundMigrationWorker.perform_async('ExtractServicesUrl', [id])
  end
end
```

We're using `after_commit` here to ensure the Sidekiq job is not scheduled
before the transaction completes as doing so can lead to race conditions where
the changes are not yet visible to the worker.

Next we'll need a post-deployment migration that schedules the migration for
existing data. Since we're dealing with a lot of rows we'll schedule jobs in
batches instead of doing this one by one:

```ruby
class ScheduleExtractServicesUrl < ActiveRecord::Migration
  disable_ddl_transaction!

  class Service < ActiveRecord::Base
    self.table_name = 'services'
  end

  def up
    Service.select(:id).in_batches do |relation|
      jobs = relation.pluck(:id).map do |id|
        ['ExtractServicesUrl', [id]]
      end

      BackgroundMigrationWorker.perform_bulk(jobs)
    end
  end

  def down
  end
end
```

Once deployed our application will continue using the data as before but at the
same time will ensure that both existing and new data is migrated.

In the next release we can remove the `after_commit` hooks and related code. We
will also need to add a post-deployment migration that consumes any remaining
jobs. Such a migration would look like this:

```ruby
class ConsumeRemainingExtractServicesUrlJobs < ActiveRecord::Migration
  disable_ddl_transaction!

  def up
    Gitlab::BackgroundMigration.steal('ExtractServicesUrl')
  end

  def down
  end
end
```

This migration will then process any jobs for the ExtractServicesUrl migration
and continue once all jobs have been processed. Once done you can safely remove
the `services.properties` column.
