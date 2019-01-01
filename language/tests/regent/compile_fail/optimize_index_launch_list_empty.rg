-- Copyright 2019 Stanford University
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- fails-with:
-- optimize_index_launch_list_empty.rg:25: loop optimization failed: body is empty
--   for i in cs do
--     ^

import "regent"

task main()
  var cs = ispace(int1d, 4)
  __demand(__parallel)
  for i in cs do
  end
end
regentlib.start(main)
