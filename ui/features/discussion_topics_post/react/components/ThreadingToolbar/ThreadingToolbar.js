/*
 * Copyright (C) 2021 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import I18n from 'i18n!discussion_posts'
import PropTypes from 'prop-types'
import React from 'react'
import {InlineList} from '@instructure/ui-list'
import {Reply} from './Reply'
import {Like} from './Like'
import {Expansion} from './Expansion'
import {Link} from '@instructure/ui-link'
import {Text} from '@instructure/ui-text'
import {Responsive} from '@instructure/ui-responsive'
import {responsiveQuerySizes} from '../../utils'
import {View} from '@instructure/ui-view'

export function ThreadingToolbar({...props}) {
  return (
    <Responsive
      match="media"
      query={responsiveQuerySizes({mobile: true, desktop: true})}
      props={{
        mobile: {
          itemSpacing: '0 small 0 0',
          textSize: 'small'
        },
        desktop: {
          itemSpacing: 'none',
          textSize: 'medium'
        }
      }}
      render={(responsiveProps, matches) =>
        (props.searchTerm || props.filter === 'unread') &&
        ENV.isolated_view &&
        !props.isIsolatedView ? (
          <Link
            as="button"
            isWithinText={false}
            data-testid="go-to-reply"
            onClick={() => {
              const isolatedId = props.discussionEntry.rootEntry
                ? props.discussionEntry.rootEntry.id
                : props.discussionEntry.id
              props.onOpenIsolatedView(
                isolatedId,
                props.discussionEntry.rootEntryId,
                false,
                props.discussionEntry._id
              )
            }}
          >
            <Text weight="bold" size={responsiveProps.textSize}>
              {I18n.t('Go to Reply')}
            </Text>
          </Link>
        ) : (
          <InlineList delimiter="pipe" display="inline-flex">
            {React.Children.map(props.children, c => (
              <InlineList.Item
                delimiter="pipe"
                key={c.props.delimiterKey}
                margin={responsiveProps.itemSpacing}
                size={responsiveProps.textSize}
                data-testid={
                  matches.includes('mobile') ? 'mobile-thread-tool' : 'desktop-thread-tool'
                }
              >
                <View style={{display: 'inline-flex'}}>{c}</View>
              </InlineList.Item>
            ))}
          </InlineList>
        )
      }
    />
  )
}

ThreadingToolbar.propTypes = {
  children: PropTypes.arrayOf(PropTypes.node),
  searchTerm: PropTypes.string,
  filter: PropTypes.string,
  onOpenIsolatedView: PropTypes.func,
  discussionEntry: PropTypes.object,
  isIsolatedView: PropTypes.bool
}

ThreadingToolbar.Reply = Reply
ThreadingToolbar.Like = Like
ThreadingToolbar.Expansion = Expansion

export default ThreadingToolbar
