import '../../core/proto.dart';
import '../../l10n/app_localizations.dart';

/// What the mission is doing, in a line.
String navStateText(AppLocalizations l, NavStatus st) => switch (st.state) {
  NavState.NAV_STATE_WAITING_GPS => l.navStateWaitingGps,
  NavState.NAV_STATE_WAITING_HEADING => l.navStateWaitingHeading,
  NavState.NAV_STATE_READY => l.navStateReady,
  NavState.NAV_STATE_DRIVING => l.navStateDriving(st.distanceM),
  NavState.NAV_STATE_BLOCKED => l.navStateBlocked,
  NavState.NAV_STATE_ARRIVED => l.navStateArrived,
  NavState.NAV_STATE_OUTSIDE_FENCE => l.navStateOutside,
  _ => l.navStateIdle,
};

/// Which mission runs ("" when none).
String navMissionText(AppLocalizations l, NavStatus st) => switch (st.mission) {
  NavAction.NAV_ACTION_GO_TO => l.navMissionGoTo,
  NavAction.NAV_ACTION_GO_HOME => l.navMissionHome,
  NavAction.NAV_ACTION_PATROL => l.navMissionPatrol(st.waypoint + 1, st.route.length),
  _ => '',
};

/// Why the robot turned a request down (null: it did not).
String? navRefusalText(AppLocalizations l, NavRefusal r) => switch (r) {
  NavRefusal.NAV_REFUSAL_NO_POSITION => l.navRefusedNoPosition,
  NavRefusal.NAV_REFUSAL_NO_HOME => l.navRefusedNoHome,
  NavRefusal.NAV_REFUSAL_NO_ROUTE => l.navRefusedNoRoute,
  NavRefusal.NAV_REFUSAL_OUTSIDE_FENCE => l.navRefusedOutsideFence,
  NavRefusal.NAV_REFUSAL_BAD_POINTS => l.navRefusedBadPoints,
  NavRefusal.NAV_REFUSAL_FOLLOWING => l.navRefusedFollowing,
  NavRefusal.NAV_REFUSAL_NOTHING_TO_RESUME => l.navRefusedNothingToResume,
  _ => null,
};

bool navMissionOn(NavStatus st) => st.mission != NavAction.NAV_ACTION_UNSPECIFIED;
