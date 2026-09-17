# A part of Elten - EltenLink / Elten Network desktop client.
# Copyright (C) 2014-2026 Dawid Pieper
# Elten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Elten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Elten. If not, see <https://www.gnu.org/licenses/>.
# Modified 2026 by Felix Valentin Herwig (sixdotsIT) for Klangten: premium packages removed, every former premium feature is available to everyone.

module EltenAPI
  module Common
    private
    # Klangten has no premium packages. These helpers are kept only so that
    # remaining callers (and programs written for Elten) keep working; they
    # always grant the feature and never show an upsell.
    def holds_premiumpackage(_package=nil)
      true
    end

    def requires_premiumpackage(_package=nil)
      true
    end
  end
end
