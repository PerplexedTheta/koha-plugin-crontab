const {
    dest,
    series,
    src
} = require('gulp');

const fs = require('fs');
const run = require('gulp-run');
const dateTime = require('node-datetime');
const Vinyl = require('vinyl');
const path = require('path');
const stream = require('stream');

const dt = dateTime.create();
const today = dt.format('Y-m-d');

const package_json = JSON.parse(fs.readFileSync('./package.json'));
const release_filename = `${package_json.name}-v${package_json.version}.kpz`;

const pm_name = 'Crontab';
const pm_file = pm_name + '.pm';
const pm_file_path = path.join('Koha', 'Plugin');
const pm_file_path_full = path.join(pm_file_path, pm_file);
const pm_file_path_dist = path.join('dist', pm_file_path);
const pm_file_path_full_dist = path.join(pm_file_path_dist, pm_file);
const pm_bundle_path = path.join(pm_file_path, pm_name);

function build() {
    return run(`
        mkdir dist ;
        cp -r Koha dist/. ;
        sed -i -e "s/{VERSION}/${package_json.version}/g" ${pm_file_path_full_dist} ;
        sed -i -e "s/1970-01-01/${today}/g" ${pm_file_path_full_dist} ;
        cd dist ;
        zip -r ../${release_filename} ./Koha ;
        cd .. ;
        rm -rf dist ;
    `).exec();
};

exports.build = build;
