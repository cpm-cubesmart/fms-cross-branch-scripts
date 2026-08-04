# Scripts

This repository has scripts that allow you to test behavior between two branches
of a rubyonrails application. Some are specific to CubeSmart's FMS application.

## USAGE for settings.rb script

For this example, I'm assuming the following:
- You have `main` checked out at /home/developer/code/fms
- You have your zeitwerk branch checked out at /home/developer/code/fms-worktrees/zeitwerk_upgrade_low_impact
- You have this repository checked out at /home/developer/code/fms-cross-branch-scripts

If your paths are different, please adjust the commands accordingly.

1. cd/checkout your main repro

        cd ~/code/fms

2. Make sure ~/code/fms/config/environments/development.rb is configured with the config.eager_load value you are
   testing for. Not working in eager mode is a show stopper, but not working in non-eager mode is also very bad.

3. Run the script and capture output.
        DISABLE_SPRING=1 bin/rails runner ../fms-cross-branch-scripts/settings.rb > ../fms-cross-branch-scripts/output_main_settings.txt

4. cd/checkout your zeitwerk repro

        cd ~/code/fms-worktrees/zeitwerk_upgrade_low_impact

5. Make sure ~/code/fms-worktrees/zeitwerk_upgrade_low_impact/config/environments/development.rb is configured with
   the config.eager_load value you are testing for.

6. Run the script and capture output.
        DISABLE_SPRING=1 bin/rails runner ../../fms-cross-branch-scripts/settings.rb > ../../fms-cross-branch-scripts/output_zeitwerk_settings.txt

7. Compare the output with diff or any other tool you want to use.

        cd ~/fms-cross-branch-scripts
        diff -u output_main_settings.txt output_zeitwerk_settings.txt > output_settings.diff

## USAGE for rails-eager-load-snapshot

TODO