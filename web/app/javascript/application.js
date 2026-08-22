// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails";
import { registerStyledConfirm } from "lib/styled_confirm";
registerStyledConfirm(window.Turbo);
import "controllers";
import "chartkick";
import "Chart.bundle";
import "lib/form_busy";
